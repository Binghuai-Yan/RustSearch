use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tauri::{AppHandle, Emitter, Manager};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{ChildStdin, Command},
    sync::{oneshot, watch, Mutex as AsyncMutex},
};

type Reply = Result<Value, String>;

pub const METHODS: &[&str] = &[
    "app.stats",
    "index.status",
    "index.list_roots",
    "index.add_root",
    "index.remove_root",
    "index.rebuild",
    "index.pause",
    "index.resume",
    "search.query",
    "search.history",
    "doc.preview",
    "config.get",
    "config.set",
    "ocr.retry_failed",
];

#[derive(Default)]
pub struct Backend {
    session: AsyncMutex<Option<Arc<Session>>>,
}

struct Session {
    input: AsyncMutex<ChildStdin>,
    pending: Mutex<HashMap<u64, oneshot::Sender<Reply>>>,
    sequence: AtomicU64,
    connected: AtomicBool,
    stop: Mutex<Option<oneshot::Sender<()>>>,
    terminated: watch::Receiver<bool>,
}

// Removing a timed-out/cancelled invoke must not accumulate pending requests.
struct Pending<'a> {
    session: &'a Session,
    id: u64,
}
impl Drop for Pending<'_> {
    fn drop(&mut self) {
        self.session.pending.lock().unwrap().remove(&self.id);
    }
}

impl Session {
    fn fail(&self, reason: &str) {
        self.connected.store(false, Ordering::SeqCst);
        for (_, response) in self.pending.lock().unwrap().drain() {
            let _ = response.send(Err(reason.to_owned()));
        }
    }

    async fn request(&self, method: &str, params: Value) -> Reply {
        let id = self.sequence.fetch_add(1, Ordering::Relaxed);
        let line = format!(
            "{}\n",
            json!({ "id": id, "method": method, "params": params })
        );
        if line.len() > 2 * 1024 * 1024 {
            return Err("请求内容超过 2 MB。".into());
        }
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.pending.lock().unwrap();
            if !self.connected.load(Ordering::SeqCst) {
                return Err("搜索引擎已断开，请重新连接。".into());
            }
            if pending.len() >= 48 {
                return Err("请求过多，请稍后重试。".into());
            }
            pending.insert(id, tx);
        }
        let _pending = Pending { session: self, id };
        // Keep writes together; a partial JSON line cannot be reused after timeout.
        let send = async {
            let mut input = self.input.lock().await;
            input.write_all(line.as_bytes()).await?;
            input.flush().await
        };
        match tokio::time::timeout(Duration::from_secs(10), send).await {
            Ok(Ok(())) => {}
            _ => {
                self.fail("无法向搜索引擎发送请求，请重新连接。");
                if let Some(stop) = self.stop.lock().unwrap().take() {
                    let _ = stop.send(());
                }
                return Err("无法向搜索引擎发送请求，请重新连接。".into());
            }
        }
        tokio::time::timeout(Duration::from_secs(60), rx)
            .await
            .map_err(|_| "搜索引擎响应超时，请稍后重试。".to_owned())?
            .map_err(|_| "搜索引擎连接中断。".to_owned())?
    }
}

pub fn executable(app: &AppHandle) -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("RUSTSEARCH_BACKEND_PATH") {
        let path = PathBuf::from(path)
            .canonicalize()
            .map_err(|e| format!("指定的搜索引擎不可用：{e}"))?;
        if !path.is_file() {
            return Err("搜索引擎路径必须指向文件。".into());
        }
        return Ok(path);
    }
    let resource = app
        .path()
        .resource_dir()
        .map_err(|e| e.to_string())?
        .join("Backend/rustsearch-backend.exe");
    if resource.is_file() {
        return Ok(resource);
    }
    #[cfg(debug_assertions)]
    {
        let repo =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../rustsearch-backend/target");
        for profile in ["debug", "release"] {
            let path = repo.join(profile).join("rustsearch-backend.exe");
            if path.is_file() {
                return Ok(path);
            }
        }
    }
    Err("找不到本地搜索引擎。请确认程序旁的 Backend 文件夹完整，或重新安装应用。".into())
}

impl Backend {
    async fn connect(&self, app: &AppHandle) -> Result<Arc<Session>, String> {
        let mut current = self.session.lock().await;
        if let Some(session) = current
            .as_ref()
            .filter(|s| s.connected.load(Ordering::SeqCst))
        {
            return Ok(session.clone());
        }
        let path = executable(app)?;
        let mut command = Command::new(&path);
        command
            .arg("--connect")
            .env(
                "RUSTSEARCH_DATA_DIR",
                app.state::<crate::desktop::Desktop>().data_directory(),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(parent) = path.parent() {
            command.current_dir(parent);
        }
        #[cfg(windows)]
        command.creation_flags(0x08000000);
        let mut child = command
            .spawn()
            .map_err(|e| format!("无法启动搜索引擎：{e}"))?;
        let input = child.stdin.take().ok_or("搜索引擎输入不可用")?;
        let output = child.stdout.take().ok_or("搜索引擎输出不可用")?;
        let error = child.stderr.take().ok_or("搜索引擎错误输出不可用")?;
        let (stop, mut stopped) = oneshot::channel();
        let (terminated_tx, terminated) = watch::channel(false);
        let session = Arc::new(Session {
            input: AsyncMutex::new(input),
            pending: Mutex::new(HashMap::new()),
            sequence: AtomicU64::new(1),
            connected: AtomicBool::new(true),
            stop: Mutex::new(Some(stop)),
            terminated,
        });
        let errors = Arc::new(Mutex::new(String::new()));
        let last_error = errors.clone();
        let stderr_task = tauri::async_runtime::spawn(async move {
            let mut lines = BufReader::new(error).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                *last_error.lock().unwrap() = line.chars().take(1500).collect();
            }
        });
        let reader_session = session.clone();
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            let mut lines = BufReader::new(output).lines();
            loop {
                tokio::select! {
                    _ = &mut stopped => break,
                    // A broker/grandchild can keep an inherited Windows pipe
                    // handle open. Process exit must also fail pending calls.
                    _ = child.wait() => break,
                    line = lines.next_line() => {
                        let Ok(Some(line)) = line else { break; };
                        let Ok(value) = serde_json::from_str::<Value>(&line) else { continue; };
                        if let Some(id) = value["id"].as_u64() {
                            if let Some(tx) = reader_session.pending.lock().unwrap().remove(&id) {
                                let result = if value["ok"] == true { Ok(value["result"].clone()) }
                                    else { Err(format!("{}: {}", value["error"]["code"].as_str().unwrap_or("ERROR"), value["error"]["message"].as_str().unwrap_or("请求失败"))) };
                                let _ = tx.send(result);
                            }
                        } else if value["event"].is_string() {
                            let _ = app.emit("backend-event", &value);
                        }
                    }
                }
            }
            let message = {
                let detail = errors.lock().unwrap();
                if detail.is_empty() {
                    "搜索引擎已断开，请重新连接。".to_owned()
                } else {
                    format!("搜索引擎已断开：{detail}")
                }
            };
            reader_session.fail(&message);
            let _ = app.emit("backend-disconnected", &message);
            // Only terminate this stdio bridge. The broker owns the shared engine.
            let _ = child.kill().await;
            let _ = child.wait().await;
            stderr_task.abort();
            let _ = terminated_tx.send(true);
        });
        *current = Some(session.clone());
        Ok(session)
    }

    pub async fn call(&self, app: &AppHandle, method: &str, params: Value) -> Reply {
        if !METHODS.contains(&method) {
            return Err("不支持的搜索引擎操作。".into());
        }
        if !params.is_object() {
            return Err("请求参数必须为对象。".into());
        }
        self.connect(app).await?.request(method, params).await
    }

    pub async fn disconnect(&self) {
        if let Some(session) = self.session.lock().await.take() {
            if session.connected.load(Ordering::SeqCst) {
                // The broker only stops the engine when this is its last
                // client; other frontends and MCP sessions remain connected.
                let _ = tokio::time::timeout(
                    Duration::from_secs(15),
                    session.request("app.shutdown", json!({})),
                )
                .await;
            }
            if let Some(stop) = session.stop.lock().unwrap().take() {
                let _ = stop.send(());
            }
            let mut terminated = session.terminated.clone();
            if !*terminated.borrow() {
                let _ = terminated.changed().await;
            }
        }
    }
}
