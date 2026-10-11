use crate::backend::{self, Backend};
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
};
use tauri::{AppHandle, Emitter, State};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
    sync::{Notify, RwLock},
};

pub struct Desktop {
    directory: Mutex<PathBuf>,
    preferences: PathBuf,
    pub gate: RwLock<()>,
    pub migrating: AtomicBool,
    cancel: Notify,
    cancel_requested: AtomicBool,
}

impl Default for Desktop {
    fn default() -> Self {
        let default =
            PathBuf::from(std::env::var_os("LOCALAPPDATA").unwrap_or_default()).join("RustSearch");
        let explicit = std::env::var_os("RUSTSEARCH_DATA_DIR").map(PathBuf::from);
        let preferences = std::env::var_os("RUSTSEARCH_PREFERENCES_DIR")
            .map(PathBuf::from)
            .or_else(|| explicit.clone())
            .unwrap_or_else(|| default.clone());
        let persisted = std::fs::read(preferences.join("ui-settings.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| v["data_directory"].as_str().map(PathBuf::from));
        Self {
            directory: Mutex::new(explicit.or(persisted).unwrap_or(default)),
            preferences,
            gate: RwLock::new(()),
            migrating: AtomicBool::new(false),
            cancel: Notify::new(),
            cancel_requested: AtomicBool::new(false),
        }
    }
}
impl Desktop {
    pub fn request_cancel(&self) {
        if self.migrating.load(Ordering::SeqCst) {
            self.cancel_requested.store(true, Ordering::SeqCst);
            self.cancel.notify_one();
        }
    }
    pub fn data_directory(&self) -> PathBuf {
        self.directory.lock().unwrap().clone()
    }
    pub fn close_to_tray(&self) -> bool {
        std::fs::read(self.data_directory().join("ui-preferences.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| v["CloseToTray"].as_bool())
            .unwrap_or(true)
    }
}

#[tauri::command]
pub fn desktop_settings(app: AppHandle, desktop: State<'_, Desktop>) -> Result<Value, String> {
    let directory = desktop.data_directory();
    let theme =
        std::fs::read_to_string(directory.join("ui-theme.txt")).unwrap_or_else(|_| "Light".into());
    let mcp = backend::executable(&app)?.with_file_name("rustsearch-mcp.exe");
    let installed = mcp.is_file();
    // Resource paths may use Windows' verbatim prefix; export ordinary paths
    // for clients whose command launchers do not accept that prefix.
    let path = mcp.to_string_lossy();
    let mcp = if let Some(unc) = path.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{unc}")
    } else {
        path.strip_prefix(r"\\?\").unwrap_or(&path).to_owned()
    };
    Ok(
        json!({ "close_to_tray": desktop.close_to_tray(), "theme": theme.trim().to_lowercase(),
        "data_directory": directory, "mcp_installed": installed, "mcp_path": mcp,
        "claude": serde_json::to_string_pretty(&json!({ "mcpServers": { "rustsearch": { "command": mcp, "args": [] } } })).unwrap(),
        "codex": format!("[mcp_servers.rustsearch]\ncommand = {}\nargs = []", serde_json::to_string(&mcp).unwrap()) }),
    )
}

#[tauri::command]
pub async fn save_desktop_settings(
    desktop: State<'_, Desktop>,
    theme: String,
    close_to_tray: bool,
) -> Result<(), String> {
    let _gate = desktop.gate.read().await;
    if !["light", "dark"].contains(&theme.as_str()) {
        return Err("请选择浅色或深色主题。".into());
    }
    let directory = desktop.data_directory();
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let temp = directory.join(format!("ui-preferences.{}.tmp", std::process::id()));
    std::fs::write(&temp, json!({ "CloseToTray": close_to_tray }).to_string())
        .map_err(|e| e.to_string())?;
    // Windows rename replaces a file atomically via MoveFileEx in Rust std.
    std::fs::rename(temp, directory.join("ui-preferences.json")).map_err(|e| e.to_string())?;
    std::fs::write(
        directory.join("ui-theme.txt"),
        if theme == "dark" { "Dark" } else { "Light" },
    )
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn cancel_migration(desktop: State<'_, Desktop>) {
    desktop.request_cancel();
}

#[tauri::command]
pub async fn change_data_directory(
    app: AppHandle,
    desktop: State<'_, Desktop>,
    backend: State<'_, Backend>,
    destination: String,
    migrate: bool,
) -> Result<Value, String> {
    let _gate = desktop
        .gate
        .try_write()
        .map_err(|_| "搜索引擎正忙，请稍后重试。")?;
    if !PathBuf::from(&destination).is_absolute() {
        return Err("请选择完整的数据目录路径。".into());
    }
    desktop.cancel_requested.store(false, Ordering::SeqCst);
    desktop.migrating.store(true, Ordering::SeqCst);
    let result = migrate_inner(&app, &desktop, &backend, destination, migrate).await;
    desktop.migrating.store(false, Ordering::SeqCst);
    result
}

async fn migrate_inner(
    app: &AppHandle,
    desktop: &Desktop,
    backend: &Backend,
    destination: String,
    migrate: bool,
) -> Result<Value, String> {
    let executable = backend::executable(app)?;
    let helper = executable.with_file_name("RustSearch.MigrationHost.exe");
    if !helper.is_file() {
        return Err("缺少数据迁移组件，请重新安装完整程序。".into());
    }
    backend.disconnect().await;
    let mut command = Command::new(helper);
    command
        .env("RUSTSEARCH_DATA_DIR", desktop.data_directory())
        .env("RUSTSEARCH_PREFERENCES_DIR", &desktop.preferences)
        .env("RUSTSEARCH_BACKEND_PATH", executable)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(0x08000000);
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    let mut input = child.stdin.take().ok_or("无法启动迁移组件")?;
    input
        .write_all(
            format!(
                "{}\n",
                json!({ "destination": destination, "migrate": migrate })
            )
            .as_bytes(),
        )
        .await
        .map_err(|e| e.to_string())?;
    let mut lines = BufReader::new(child.stdout.take().ok_or("无法读取迁移进度")?).lines();
    let mut result = None;
    loop {
        tokio::select! {
            _ = desktop.cancel.notified() => {
                if desktop.cancel_requested.load(Ordering::SeqCst) {
                    let _ = input.write_all(b"cancel\n").await;
                }
            },
            line = lines.next_line() => {
                let Some(line) = line.map_err(|e| e.to_string())? else { break; };
                let value: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
                if value.get("progress").is_some() { let _ = app.emit("migration-progress", &value["progress"]); }
                else { result = Some(value); }
            }
        }
    }
    child.wait().await.map_err(|e| e.to_string())?;
    let value = result.ok_or("迁移组件未返回结果，原数据仍保留。")?;
    if let Some(path) = value["data_directory"].as_str() {
        *desktop.directory.lock().unwrap() = PathBuf::from(path);
    }
    if value["ok"] != true {
        return Err(value["error"].as_str().unwrap_or("迁移失败").to_owned());
    }
    Ok(value)
}
