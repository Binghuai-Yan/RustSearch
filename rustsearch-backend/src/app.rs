use crate::{
    index::{builder, tokenizer, Engine},
    ipc::protocol::{PathParams, RebuildParams, Request, Response, SearchParams},
    path_utils, query,
};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{atomic::Ordering, Arc},
};
use tantivy::Term;

pub enum Job {
    Scan { root: Option<String>, force: bool },
}
#[derive(Clone)]
pub struct App {
    pub engine: Arc<Engine>,
    pub jobs: crossbeam_channel::Sender<Job>,
}
type RpcResult = std::result::Result<Value, (&'static str, String)>;
fn params<T: DeserializeOwned>(value: Value) -> std::result::Result<T, (&'static str, String)> {
    serde_json::from_value(value).map_err(|e| ("INVALID_PARAMS", e.to_string()))
}
fn internal(error: impl std::fmt::Display) -> (&'static str, String) {
    ("INTERNAL_ERROR", error.to_string())
}
impl App {
    pub fn dispatch(&self, req: Request) -> Response {
        match self.handle(&req.method, req.params) {
            Ok(value) => Response::success(req.id, value),
            Err((code, message)) => Response::failure(Some(req.id), code, message),
        }
    }
    fn schedule(
        &self,
        root: Option<String>,
        force: bool,
    ) -> std::result::Result<(), (&'static str, String)> {
        self.jobs
            .try_send(Job::Scan { root, force })
            .map_err(|_| ("INDEX_BUSY", "Index queue is full".into()))
    }
    fn schedule_root(&self, root: String) -> std::result::Result<(), (&'static str, String)> {
        self.jobs
            .try_send(Job::Scan {
                root: Some(root),
                force: false,
            })
            .map_err(|error| match error {
                crossbeam_channel::TrySendError::Full(_) => {
                    ("INDEX_BUSY", "Index queue is full".into())
                }
                crossbeam_channel::TrySendError::Disconnected(_) => {
                    ("INTERNAL_ERROR", "Index worker is unavailable".into())
                }
            })
    }
    fn handle(&self, method: &str, value: Value) -> RpcResult {
        let engine = &self.engine;
        match method {
            "app.stats" | "index.status" => {
                let meta = engine.meta.lock().unwrap();
                let (ocr_pending, ocr_failed) = meta.ocr_counts().map_err(internal)?;
                Ok(
                    json!({"version":option_env!("RUSTSEARCH_VERSION").unwrap_or(env!("CARGO_PKG_VERSION")),"total_docs":engine.reader.searcher().num_docs(),"failed_docs":meta.failed_count().map_err(internal)?,
                    "roots":meta.root_paths().map_err(internal)?.len(),"indexing":engine.indexing.load(Ordering::SeqCst),"paused":engine.paused(),"index_size_bytes":directory_size(&engine.data_dir),
                    "ocr_pending":ocr_pending,"ocr_failed":ocr_failed}),
                )
            }
            "index.list_roots" => {
                Ok(json!({"roots":engine.meta.lock().unwrap().roots().map_err(internal)?}))
            }
            "index.add_root" => {
                let p: PathParams = params(value)?;
                let root = path_utils::canonical(Path::new(&p.path))
                    .map_err(|e| ("ROOT_NOT_FOUND", e.to_string()))?;
                if !root.is_dir() {
                    return Err(("INVALID_PARAMS", "Root must be a folder".into()));
                }
                let key = path_utils::key(&root);
                if path_utils::within(&key, &path_utils::key(&engine.data_dir)) {
                    return Err(("INVALID_PARAMS", "Cannot index application data".into()));
                }
                let display = path_utils::display_path(&root);
                let inserted = engine
                    .meta
                    .lock()
                    .unwrap()
                    .add_root(&key, &display)
                    .map_err(internal)?;
                // Root registration is intentionally independent from an active scan. The
                // scanner snapshots roots at its start, so this job is queued and processed
                // immediately after the current scan releases the mutation lock.
                if let Err(error) = self.schedule_root(display.clone()) {
                    // Do not leave a root registered when the worker has gone away or the
                    // queue is unavailable. A later retry can then register it cleanly.
                    if inserted {
                        let _ = engine.meta.lock().unwrap().remove_root(&key, &[]);
                    }
                    return Err(error);
                }
                Ok(json!({"root":display}))
            }
            "index.remove_root" => {
                let p: PathParams = params(value)?;
                let key = path_utils::canonical(Path::new(&p.path))
                    .map(|path| path_utils::key(&path))
                    .unwrap_or_else(|_| path_utils::key(Path::new(&p.path)));
                let _mutation = engine
                    .mutations
                    .try_lock()
                    .map_err(|_| ("INDEX_BUSY", "Index is busy".into()))?;
                let mut meta = engine.meta.lock().unwrap();
                let roots = meta.root_paths().map_err(internal)?;
                if !roots.iter().any(|r| path_utils::key(Path::new(r)) == key) {
                    return Err(("ROOT_NOT_FOUND", "Root not registered".into()));
                }
                let remaining: Vec<_> = roots
                    .iter()
                    .map(|r| path_utils::key(Path::new(r)))
                    .filter(|k| *k != key)
                    .collect();
                let mut known: std::collections::HashMap<_, _> = meta
                    .all_files()
                    .map_err(internal)?
                    .into_iter()
                    .map(|(path, file)| (path, file.display_path))
                    .collect();
                known.extend(meta.pending_paths().map_err(internal)?);
                let staged: Vec<_> = known
                    .into_iter()
                    .filter(|(path, _)| {
                        path_utils::within(path, &key)
                            && !remaining.iter().any(|r| path_utils::within(path, r))
                    })
                    .collect();
                let removed: Vec<_> = staged.iter().map(|(path, _)| path.clone()).collect();
                meta.stage_paths(&staged).map_err(internal)?;
                let mut writer = engine.writer.lock().unwrap();
                for path in &removed {
                    writer.delete_term(Term::from_field_text(engine.fields.path, path));
                }
                writer.commit().map_err(internal)?;
                meta.remove_root(&key, &removed).map_err(internal)?;
                engine.committed().map_err(internal)?;
                Ok(json!({"root":p.path,"removed":removed.len()}))
            }
            "index.rebuild" => {
                let p: RebuildParams = params(value)?;
                let roots = engine.meta.lock().unwrap().root_paths().map_err(internal)?;
                let root = roots
                    .into_iter()
                    .find(|r| {
                        let requested = path_utils::canonical(Path::new(&p.root))
                            .map(|path| path_utils::key(&path))
                            .unwrap_or_else(|_| path_utils::key(Path::new(&p.root)));
                        path_utils::key(Path::new(r)) == requested
                    })
                    .ok_or(("ROOT_NOT_FOUND", "Root not registered".into()))?;
                self.schedule(Some(root.clone()), true)?;
                Ok(json!({"root":root}))
            }
            "index.pause" | "index.resume" => {
                let mut config = engine.config.lock().unwrap();
                config.paused = method == "index.pause";
                config.save(&engine.data_dir).map_err(internal)?;
                let paused = config.paused;
                drop(config);
                if !paused {
                    self.schedule(None, false)?;
                }
                Ok(json!({"paused":paused}))
            }
            "search.query" => {
                let p: SearchParams = params(value)?;
                query::validate_search(&p).map_err(|e| ("INVALID_PARAMS", e.to_string()))?;
                query::search(engine, p)
                    .and_then(|r| Ok(serde_json::to_value(r)?))
                    .map_err(|e| {
                        (
                            if e.is::<query::QuerySyntaxError>() {
                                "QUERY_SYNTAX_ERROR"
                            } else {
                                "INTERNAL_ERROR"
                            },
                            e.to_string(),
                        )
                    })
            }
            "search.history" => {
                Ok(json!({"queries":engine.meta.lock().unwrap().history().map_err(internal)?}))
            }
            "doc.preview" => {
                let p: PathParams = params(value)?;
                let path = path_utils::canonical(Path::new(&p.path))
                    .map_err(|e| ("EXTRACT_FAILED", e.to_string()))?;
                let roots = engine.meta.lock().unwrap().root_paths().map_err(internal)?;
                if !roots.iter().any(|root| {
                    path_utils::within(&path_utils::key(&path), &path_utils::key(Path::new(root)))
                }) {
                    return Err((
                        "INVALID_PARAMS",
                        "Preview must be within an indexed root".into(),
                    ));
                }
                let max = engine.config.lock().unwrap().max_file_size_mb * 1024 * 1024;
                if std::fs::metadata(&path).map_err(internal)?.len() > max {
                    return Err((
                        "EXTRACT_FAILED",
                        "File exceeds configured size limit".into(),
                    ));
                }
                let key = path_utils::key(&path);
                let cached = {
                    let meta = engine.meta.lock().unwrap();
                    meta.file(&key).map_err(internal)?.and_then(|file| {
                        let current = std::fs::metadata(&path).ok()?;
                        let modified = current
                            .modified()
                            .ok()?
                            .duration_since(std::time::UNIX_EPOCH)
                            .ok()?;
                        if file.size == current.len() && file.mtime_ns == modified.as_nanos() as i64
                        {
                            Some((
                                meta.content(&key).ok()?,
                                meta.ocr_pages(&key).ok()?,
                                file.status,
                            ))
                        } else {
                            None
                        }
                    })
                };
                if let Some((text, pages, status)) = cached {
                    return Ok(
                        json!({"path":path_utils::display_path(&path),"text":text,"truncated":false,
                        "needs_ocr":status==2,"ocr_pages":pages.iter().map(|(page,offset,length)|
                            json!({"page":page,"offset":offset,"length":length})).collect::<Vec<_>>() }),
                    );
                }
                let result = builder::extract_file(&path)
                    .map_err(|e| ("EXTRACT_FAILED", format!("{e:#}")))?;
                Ok(
                    json!({"path":path_utils::display_path(&path),"text":result.text,"title":result.title,"truncated":result.truncated,"needs_ocr":result.needs_ocr}),
                )
            }
            "ocr.retry_failed" => {
                engine
                    .meta
                    .lock()
                    .unwrap()
                    .retry_ocr_failures()
                    .map_err(internal)?;
                Ok(json!({"queued":true}))
            }
            "config.get" => serde_json::to_value(&*engine.config.lock().unwrap()).map_err(internal),
            "config.set" => {
                let _mutation = engine.mutations.try_lock().map_err(|_| {
                    (
                        "INDEX_BUSY",
                        "Wait for indexing to finish before changing extraction settings".into(),
                    )
                })?;
                let mut config = engine.config.lock().unwrap();
                let next = config
                    .patch(value)
                    .map_err(|e| ("INVALID_PARAMS", e.to_string()))?;
                let dictionary_changed = next.user_dictionary != config.user_dictionary;
                let ocr_changed = next.ocr_enabled != config.ocr_enabled
                    || next.ocr_images != config.ocr_images
                    || next.ocr_pdf != config.ocr_pdf
                    || next.ocr_max_pages != config.ocr_max_pages;
                tokenizer::MixedTokenizer::new(&next.user_dictionary)
                    .map_err(|e| ("INVALID_PARAMS", e.to_string()))?;
                next.save(&engine.data_dir).map_err(internal)?;
                tokenizer::register(&engine.index, &next.user_dictionary).map_err(internal)?;
                *config = next.clone();
                drop(config);
                if ocr_changed {
                    engine
                        .meta
                        .lock()
                        .unwrap()
                        .retry_ocr_failures()
                        .map_err(internal)?;
                    if next.ocr_enabled && next.ocr_pdf {
                        engine
                            .meta
                            .lock()
                            .unwrap()
                            .queue_pdf_ocr()
                            .map_err(internal)?;
                    }
                }
                engine.cache.lock().unwrap().clear();
                self.schedule(None, dictionary_changed)?;
                serde_json::to_value(next).map_err(internal)
            }
            _ => Err(("INVALID_PARAMS", format!("Unknown method: {method}"))),
        }
    }
}
pub fn worker(
    engine: Arc<Engine>,
    rx: crossbeam_channel::Receiver<Job>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        while !engine.stopped() {
            match rx.recv_timeout(std::time::Duration::from_millis(100)) {
                Ok(Job::Scan { root, force }) => {
                    if let Err(e) = builder::scan(&engine, root.as_deref(), force, false) {
                        engine.log("error", format!("Indexing failed: {e:#}"));
                    }
                }
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
                _ => {}
            }
        }
    })
}
fn directory_size(dir: &Path) -> u64 {
    fn size(dir: &Path, depth: usize) -> u64 {
        if depth > 3 {
            return 0;
        }
        std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok())
            .map(|e| {
                e.metadata()
                    .map(|m| {
                        if m.is_dir() {
                            size(&e.path(), depth + 1)
                        } else {
                            m.len()
                        }
                    })
                    .unwrap_or(0)
            })
            .sum()
    }
    size(dir, 0)
}
