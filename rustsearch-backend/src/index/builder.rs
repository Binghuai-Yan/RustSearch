use super::{meta_db::FileMeta, Engine};
use crate::{
    extract,
    ipc::protocol::{IndexFinished, IndexProgress, WatcherChange},
    path_utils,
};
use anyhow::{Context, Result};
use ignore::WalkBuilder;
use rayon::prelude::*;
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant, UNIX_EPOCH},
};
use tantivy::{doc, Term};

const FULL_COMMIT_DOCS: usize = 5_000;
const FULL_COMMIT_BYTES: usize = 64 * 1024 * 1024;
const WATCH_COMMIT_DOCS: usize = 50;
const WATCH_COMMIT_INTERVAL: Duration = Duration::from_secs(30);
// Extraction is parallelized in bounded batches. A larger batch keeps rayon workers busy for
// roots containing many small files, while 32 limits peak memory for large documents.
const EXTRACTION_BATCH_SIZE: usize = 32;

struct IndexingGuard<'a>(&'a Engine);
impl Drop for IndexingGuard<'_> {
    fn drop(&mut self) {
        self.0.indexing.store(false, Ordering::SeqCst);
    }
}

pub fn eligible(path: &Path, config: &crate::config::Config, data_dir: &Path) -> bool {
    if path_utils::within(&path_utils::key(path), &path_utils::key(data_dir)) {
        return false;
    }
    if path
        .file_name()
        .is_some_and(|n| n.to_string_lossy().starts_with("~$"))
    {
        return false;
    }
    if path.components().any(|p| {
        config
            .skip_dirs
            .iter()
            .any(|s| s.eq_ignore_ascii_case(&p.as_os_str().to_string_lossy()))
    }) {
        return false;
    }
    extract::supported_extension(
        &path
            .extension()
            .unwrap_or_default()
            .to_string_lossy()
            .to_lowercase(),
    )
}
fn file_meta(path: &Path) -> Result<FileMeta> {
    let meta = fs::metadata(path)?;
    let modified = meta
        .modified()?
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    Ok(FileMeta {
        path: path_utils::key(path),
        display_path: path_utils::display_path(path),
        size: meta.len(),
        mtime: modified.as_secs(),
        mtime_ns: modified.as_nanos().min(i64::MAX as u128) as i64,
        ext: path
            .extension()
            .unwrap_or_default()
            .to_string_lossy()
            .to_lowercase(),
        status: 0,
    })
}

pub fn scan(
    engine: &Arc<Engine>,
    only_root: Option<&str>,
    force: bool,
    watching: bool,
) -> Result<WatcherChange> {
    scan_impl(engine, only_root, force, watching, None)
}

pub fn scan_paths(engine: &Arc<Engine>, paths: &[PathBuf]) -> Result<WatcherChange> {
    let keys = paths.iter().map(|p| path_utils::key(p)).collect::<Vec<_>>();
    scan_impl(engine, None, false, true, Some(&keys))
}

fn scan_impl(
    engine: &Arc<Engine>,
    only_root: Option<&str>,
    force: bool,
    watching: bool,
    scope: Option<&[String]>,
) -> Result<WatcherChange> {
    let _mutation = engine.mutations.lock().unwrap();
    if engine.stopped() || engine.paused() {
        return Ok(WatcherChange::default());
    }
    engine.indexing.store(true, Ordering::SeqCst);
    engine.retry_needed.store(false, Ordering::Relaxed);
    let _guard = IndexingGuard(engine);
    let started = Instant::now();
    let walk_started = Instant::now();
    let roots = engine.meta.lock().unwrap().root_paths()?;
    let roots: Vec<_> = roots
        .into_iter()
        .filter(|r| {
            only_root.is_none_or(|p| path_utils::key(Path::new(r)) == path_utils::key(Path::new(p)))
        })
        .collect();
    let config = engine.config.lock().unwrap().clone();
    let old = engine.meta.lock().unwrap().all_files()?;
    let pending = engine.meta.lock().unwrap().pending_paths()?;
    // A journal identifies exactly what must be retried, including operations on offline roots.
    let force = force || (pending.is_empty() && engine.meta.lock().unwrap().is_dirty()?);
    let mut discovered = HashSet::new();
    let mut changed = Vec::new();
    let mut available_roots = Vec::new();
    let mut incomplete_roots = Vec::new();
    for root in &roots {
        let root_path = PathBuf::from(root);
        if !root_path.is_dir() {
            engine.log("warn", format!("Root unavailable: {root}"));
            continue;
        }
        let root_key = path_utils::key(&root_path);
        available_roots.push(root_key.clone());
        let skipped = config.skip_dirs.clone();
        let data_key = path_utils::key(&engine.data_dir);
        let scope = scope.map(<[String]>::to_vec);
        let mut walker = WalkBuilder::new(&root_path);
        walker
            .hidden(true)
            .git_ignore(true)
            .git_global(false)
            .git_exclude(true)
            .require_git(false)
            .follow_links(false)
            .filter_entry(move |entry| {
                let key = path_utils::key(entry.path());
                let relevant = scope.as_ref().is_none_or(|paths| {
                    paths.iter().any(|path| {
                        path_utils::within(&key, path)
                            || (entry.file_type().is_some_and(|t| t.is_dir())
                                && path_utils::within(path, &key))
                    })
                });
                relevant
                    && !path_utils::within(&key, &data_key)
                    && (entry.depth() == 0
                        || !entry.file_type().is_some_and(|t| t.is_dir())
                        || !skipped
                            .iter()
                            .any(|s| s.eq_ignore_ascii_case(&entry.file_name().to_string_lossy())))
            });
        for entry in walker.build() {
            if engine.stopped() {
                return Ok(WatcherChange::default());
            }
            let entry = match entry {
                Ok(e) => e,
                Err(e) => {
                    engine.log("warn", e.to_string());
                    incomplete_roots.push(root_key.clone());
                    continue;
                }
            };
            if !entry.file_type().is_some_and(|t| t.is_file())
                || !eligible(entry.path(), &config, &engine.data_dir)
            {
                continue;
            }
            let key = path_utils::key(entry.path());
            if !discovered.insert(key.clone()) {
                continue;
            }
            match file_meta(entry.path()) {
                Ok(mut meta) => {
                    if meta.size > config.max_file_size_mb * 1024 * 1024 {
                        meta.status = 3;
                    }
                    if force
                        || pending.contains_key(&key)
                        || old.get(&key).is_none_or(|m| {
                            m.size != meta.size
                                || m.mtime_ns != meta.mtime_ns
                                || m.display_path != meta.display_path
                                || m.status == 1
                                || (m.status == 3) != (meta.status == 3)
                        })
                    {
                        changed.push((entry.into_path(), meta));
                    }
                }
                Err(e) => {
                    engine.log("warn", e.to_string());
                    engine.retry_needed.store(true, Ordering::Relaxed);
                    let meta = old.get(&key).cloned().unwrap_or_else(|| FileMeta {
                        path: key,
                        display_path: path_utils::display_path(entry.path()),
                        size: 0,
                        mtime: 0,
                        mtime_ns: 0,
                        ext: entry
                            .path()
                            .extension()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .to_lowercase(),
                        status: 0,
                    });
                    changed.push((entry.into_path(), meta));
                }
            }
        }
    }
    let known_paths: HashSet<_> = old.keys().chain(pending.keys()).cloned().collect();
    let removed: Vec<String> = known_paths
        .into_iter()
        .filter(|key| {
            !discovered.contains(key)
                && scope.is_none_or(|paths| paths.iter().any(|path| path_utils::within(key, path)))
                && available_roots
                    .iter()
                    .any(|root| path_utils::within(key, root))
                && !incomplete_roots
                    .iter()
                    .any(|root| path_utils::within(key, root))
        })
        .collect();
    let root_label = only_root.unwrap_or("").to_owned();
    let total = changed.len();
    tracing::info!(
        elapsed_ms = walk_started.elapsed().as_millis() as u64,
        discovered = discovered.len(),
        changed = total,
        removed = removed.len(),
        "index walk complete"
    );
    let done = AtomicUsize::new(0);
    let failed = AtomicUsize::new(0);
    let mut change = WatcherChange::default();
    if changed.is_empty() && removed.is_empty() {
        if !watching {
            engine.out.event(
                "index.finished",
                serde_json::to_value(IndexFinished {
                    root: root_label,
                    total_docs: engine.reader.searcher().num_docs() as usize,
                    failed: 0,
                    elapsed_s: started.elapsed().as_secs_f64(),
                })?,
            );
        }
        return Ok(change);
    }
    engine.out.event(
        "index.progress",
        serde_json::to_value(IndexProgress {
            root: root_label.clone(),
            total,
            done: 0,
            failed: 0,
            current_file: String::new(),
        })?,
    );
    let mut writer = engine.writer.lock().unwrap();
    engine.meta.lock().unwrap().mark_dirty()?;
    let mut pending_records = vec![];
    let mut pending_staged = vec![];
    let mut pending_bytes = 0usize;
    let mut last_commit = Instant::now();
    let mut extract_elapsed = Duration::ZERO;
    let mut tantivy_elapsed = Duration::ZERO;
    let mut sqlite_elapsed = Duration::ZERO;
    let commit_docs = if watching {
        WATCH_COMMIT_DOCS
    } else {
        FULL_COMMIT_DOCS
    };
    let commit_bytes = if watching {
        16 * 1024 * 1024
    } else {
        FULL_COMMIT_BYTES
    };
    // Keep extracted text bounded to a small batch, even for very large roots.
    for batch in changed.chunks(EXTRACTION_BATCH_SIZE) {
        while engine.paused() && !engine.stopped() {
            std::thread::sleep(Duration::from_millis(100));
        }
        if engine.stopped() {
            break;
        }
        let extract_started = Instant::now();
        let extracted: Vec<_> = batch.par_iter().map(|(path,meta)| {
            let mut meta = meta.clone();
            let result = if meta.status==3 { None } else { Some(extract_file(path)) };
            if result.as_ref().is_some_and(|r| r.is_err()) { meta.status=1; failed.fetch_add(1,Ordering::Relaxed); }
            let n = done.fetch_add(1,Ordering::Relaxed)+1;
                if n.is_multiple_of(100) || n==total { engine.out.event("index.progress",serde_json::json!({"root":root_label,"total":total,"done":n,"failed":failed.load(Ordering::Relaxed),"current_file":meta.display_path})); }
            (meta,result)
        }).collect();
        extract_elapsed += extract_started.elapsed();
        // Compression is independent for every document. Do it on rayon workers so a large
        // text file cannot serialize the writer loop and stall extraction of the rest batch.
        let compressed: Vec<Option<Vec<u8>>> = extracted
            .par_iter()
            .map(|(_, result)| match result {
                Some(Ok(result)) => zstd::encode_all(result.text.as_bytes(), 1)
                    .map(Some)
                    .context("compress extracted text"),
                _ => Ok(None),
            })
            .collect::<Result<Vec<_>>>()?;
        let staged: Vec<_> = extracted
            .iter()
            .filter(|(_, result)| result.as_ref().is_none_or(|result| result.is_ok()))
            .map(|(meta, _)| (meta.path.clone(), meta.display_path.clone()))
            .collect();
        pending_staged.extend(staged);
        let tantivy_started = Instant::now();
        let mut records = vec![];
        for ((mut meta, result), compressed) in extracted.into_iter().zip(compressed) {
            match result {
                Some(Ok(result)) => {
                    // Detect a concurrent save; retry next scan without deleting the old document.
                    if file_meta(Path::new(&meta.display_path)).is_ok_and(|latest| {
                        latest.size != meta.size || latest.mtime_ns != meta.mtime_ns
                    }) {
                        meta.status = 1;
                        engine.retry_needed.store(true, Ordering::Relaxed);
                        records.push((meta, None));
                        continue;
                    }
                    meta.status = if result.needs_ocr { 2 } else { 0 };
                    if old.contains_key(&meta.path) || pending.contains_key(&meta.path) {
                        writer.delete_term(Term::from_field_text(engine.fields.path, &meta.path));
                    }
                    let filename = Path::new(&meta.display_path)
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy();
                    writer.add_document(doc!(engine.fields.path=>meta.path.clone(),engine.fields.display_path=>meta.display_path.clone(),
                        engine.fields.filename=>filename.as_ref(),engine.fields.content=>result.text,engine.fields.ext=>meta.ext.clone(),
                        engine.fields.size=>meta.size,engine.fields.mtime=>meta.mtime,engine.fields.title=>result.title.unwrap_or_default()))?;
                    if old.contains_key(&meta.path) {
                        change.modified += 1;
                    } else {
                        change.added += 1;
                    }
                    records.push((meta, compressed));
                }
                Some(Err(error)) => {
                    if error
                        .chain()
                        .filter_map(|e| e.downcast_ref::<std::io::Error>())
                        .any(|e| {
                            matches!(e.raw_os_error(), Some(5 | 32 | 33))
                                || matches!(
                                    e.kind(),
                                    std::io::ErrorKind::WouldBlock
                                        | std::io::ErrorKind::PermissionDenied
                                )
                        })
                    {
                        engine.retry_needed.store(true, Ordering::Relaxed);
                    }
                    engine.log("warn", format!("{}: {error:#}", meta.display_path));
                    records.push((meta, None));
                }
                None => {
                    if old.contains_key(&meta.path) || pending.contains_key(&meta.path) {
                        writer.delete_term(Term::from_field_text(engine.fields.path, &meta.path));
                    }
                    records.push((meta, None));
                }
            }
        }
        tantivy_elapsed += tantivy_started.elapsed();
        // Commit the index before atomically completing metadata and its durable operation journal.
        pending_bytes += records
            .iter()
            .filter_map(|(_, text)| text.as_ref().map(Vec::len))
            .sum::<usize>();
        pending_records.extend(records);
        if pending_records.len() >= commit_docs
            || pending_bytes >= commit_bytes
            || (watching && last_commit.elapsed() >= WATCH_COMMIT_INTERVAL)
        {
            let sqlite_started = Instant::now();
            engine.meta.lock().unwrap().stage_paths(&pending_staged)?;
            writer.commit()?;
            engine
                .meta
                .lock()
                .unwrap()
                .save_batch(&pending_records, &[])?;
            engine.committed()?;
            engine.meta.lock().unwrap().mark_dirty()?;
            sqlite_elapsed += sqlite_started.elapsed();
            pending_staged.clear();
            pending_records.clear();
            pending_bytes = 0;
            last_commit = Instant::now();
        }
    }
    if !engine.stopped() {
        let staged: Vec<_> = removed
            .iter()
            .map(|key| {
                (
                    key.clone(),
                    old.get(key)
                        .map(|meta| meta.display_path.clone())
                        .or_else(|| pending.get(key).cloned())
                        .unwrap_or_else(|| key.clone()),
                )
            })
            .collect();
        pending_staged.extend(staged);
        for key in &removed {
            writer.delete_term(Term::from_field_text(engine.fields.path, key));
        }
        change.removed = removed.len();
        if !pending_records.is_empty() || !removed.is_empty() {
            let sqlite_started = Instant::now();
            engine.meta.lock().unwrap().stage_paths(&pending_staged)?;
            writer.commit()?;
            engine
                .meta
                .lock()
                .unwrap()
                .save_batch(&pending_records, &removed)?;
            engine.committed()?;
            sqlite_elapsed += sqlite_started.elapsed();
        }
    }
    tracing::info!(
        extract_ms = extract_elapsed.as_millis() as u64,
        tantivy_ms = tantivy_elapsed.as_millis() as u64,
        sqlite_ms = sqlite_elapsed.as_millis() as u64,
        "index pipeline complete"
    );
    let total_docs = engine.reader.searcher().num_docs() as usize;
    engine.out.event(
        "index.finished",
        serde_json::to_value(IndexFinished {
            root: root_label,
            total_docs,
            failed: failed.load(Ordering::Relaxed),
            elapsed_s: started.elapsed().as_secs_f64(),
        })?,
    );
    if watching && change.added + change.modified + change.removed > 0 {
        engine
            .out
            .event("watcher.change", serde_json::to_value(&change)?);
    }
    Ok(change)
}

pub fn extract_file(path: &Path) -> Result<extract::ExtractResult> {
    if !path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("pdf"))
    {
        return extract::extract(path);
    }
    use std::{
        io::Read,
        process::{Command, Stdio},
    };
    let result_file = tempfile::Builder::new()
        .prefix("rustsearch-pdf-")
        .suffix(".json")
        .tempfile()?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("--extract-one")
        .arg(path)
        .arg(result_file.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let mut child = command
        .spawn()
        .context("Cannot start PDF extraction worker")?;
    let start = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let mut bytes = Vec::new();
            fs::File::open(result_file.path())?
                .take((extract::MAX_TEXT_SIZE * 6 + 4096) as u64)
                .read_to_end(&mut bytes)?;
            let value: serde_json::Value =
                serde_json::from_slice(&bytes).context("Invalid PDF worker output")?;
            anyhow::ensure!(
                status.success(),
                "{}",
                value["error"].as_str().unwrap_or("PDF extraction failed")
            );
            return Ok(extract::ExtractResult {
                text: value["text"].as_str().unwrap_or_default().to_owned(),
                title: value["title"].as_str().map(str::to_owned),
                truncated: value["truncated"].as_bool().unwrap_or(false),
                needs_ocr: value["needs_ocr"].as_bool().unwrap_or(false),
            });
        }
        if start.elapsed() > Duration::from_secs(10) {
            let _ = child.kill();
            let _ = child.wait();
            anyhow::bail!("PDF extraction timed out after 10 seconds");
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}
