//! Local shared-engine broker. Each frontend retains its own stdio connection.
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{collections::HashMap, path::PathBuf, process::Stdio, time::Duration};
use tokio::net::windows::named_pipe::{ClientOptions, NamedPipeClient, ServerOptions};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
    sync::mpsc,
};

pub fn data_dir() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("RUSTSEARCH_DATA_DIR") {
        return Ok(std::path::absolute(PathBuf::from(path))?);
    }
    let default = PathBuf::from(std::env::var_os("LOCALAPPDATA").context("LOCALAPPDATA missing")?)
        .join("RustSearch");
    let prefs = std::env::var_os("RUSTSEARCH_PREFERENCES_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| default.clone());
    if let Ok(bytes) = std::fs::read(prefs.join("ui-settings.json")) {
        let value: Value = serde_json::from_slice(&bytes)?;
        if let Some(path) = value["data_directory"]
            .as_str()
            .filter(|p| !p.trim().is_empty())
        {
            return Ok(std::path::absolute(path)?);
        }
    }
    Ok(default)
}

pub fn backend_exe() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("RUSTSEARCH_BACKEND_PATH") {
        return Ok(PathBuf::from(path));
    }
    Ok(std::env::current_exe()?.with_file_name("rustsearch-backend.exe"))
}

fn user_sid() -> Result<String> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, LocalFree},
        Security::{
            Authorization::ConvertSidToStringSidW, GetTokenInformation, TokenUser, TOKEN_QUERY,
            TOKEN_USER,
        },
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    };
    unsafe {
        let mut token = std::ptr::null_mut();
        anyhow::ensure!(
            OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) != 0,
            "Cannot open user token"
        );
        let mut length = 0;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut length);
        let mut buffer = vec![0u64; (length as usize).div_ceil(8)];
        let ok = GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            length,
            &mut length,
        );
        CloseHandle(token);
        anyhow::ensure!(ok != 0, "Cannot read user token");
        let user = &*(buffer.as_ptr() as *const TOKEN_USER);
        let mut sid = std::ptr::null_mut();
        anyhow::ensure!(
            ConvertSidToStringSidW(user.User.Sid, &mut sid) != 0,
            "Cannot convert SID"
        );
        let mut count = 0;
        while *sid.add(count) != 0 {
            count += 1;
        }
        let value = String::from_utf16_lossy(std::slice::from_raw_parts(sid, count));
        LocalFree(sid.cast());
        Ok(value)
    }
}

fn pipe_name() -> Result<String> {
    use sha2::{Digest, Sha256};
    let dir = data_dir()?;
    std::fs::create_dir_all(&dir)?;
    let normalized = std::fs::canonicalize(dir)?.to_string_lossy().to_lowercase();
    let digest = Sha256::digest(format!("{}|{normalized}", user_sid()?));
    Ok(format!(r"\\.\pipe\RustSearch-{:x}", digest))
}

fn create_pipe(
    name: &str,
    first: bool,
) -> Result<tokio::net::windows::named_pipe::NamedPipeServer> {
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::{
            Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW,
            SECURITY_ATTRIBUTES,
        },
    };
    let sddl: Vec<u16> = format!("D:P(A;;GA;;;{})", user_sid()?)
        .encode_utf16()
        .chain(Some(0))
        .collect();
    unsafe {
        let mut descriptor = std::ptr::null_mut();
        anyhow::ensure!(
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                1,
                &mut descriptor,
                std::ptr::null_mut()
            ) != 0,
            "Cannot create pipe ACL"
        );
        let mut attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        let result = ServerOptions::new()
            .first_pipe_instance(first)
            .reject_remote_clients(true)
            .create_with_security_attributes_raw(
                name,
                (&mut attributes as *mut SECURITY_ATTRIBUTES).cast(),
            );
        LocalFree(descriptor);
        Ok(result?)
    }
}

pub async fn connect(readonly: bool) -> Result<NamedPipeClient> {
    let name = pipe_name()?;
    let mut spawned: Option<tokio::process::Child> = None;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while tokio::time::Instant::now() < deadline {
        match ClientOptions::new().open(&name) {
            Ok(mut pipe) => {
                // A listening pipe can belong to a broker that is draining its
                // previous engine. Confirm readiness using the existing RPC
                // protocol before starting any frontend's stdio reader.
                let ready = async {
                    pipe.write_all(
                        format!(
                            "{}\n{}\n",
                            json!({"role":if readonly {"mcp"} else {"desktop"},"protocol":1}),
                            json!({"id":0,"method":"app.stats","params":{}})
                        )
                        .as_bytes(),
                    )
                    .await?;
                    let mut lines = BufReader::new(&mut pipe).lines();
                    while let Some(line) = lines.next_line().await? {
                        let value: Value = serde_json::from_str(&line)?;
                        if value["id"] == 0 {
                            anyhow::ensure!(value["ok"] == true, "Shared engine is not ready");
                            return Ok::<(), anyhow::Error>(());
                        }
                    }
                    bail!("Shared broker disconnected during startup")
                };
                if matches!(
                    tokio::time::timeout(Duration::from_secs(3), ready).await,
                    Ok(Ok(()))
                ) {
                    return Ok(pipe);
                }
            }
            Err(error) if matches!(error.raw_os_error(), Some(2 | 231)) => {
                if spawned
                    .as_mut()
                    .is_none_or(|child| child.try_wait().is_ok_and(|status| status.is_some()))
                {
                    let logs = data_dir()?.join("logs");
                    std::fs::create_dir_all(&logs)?;
                    let log = logs.join("shared-engine.log");
                    if std::fs::metadata(&log).is_ok_and(|meta| meta.len() > 2 * 1024 * 1024) {
                        let _ = std::fs::remove_file(&log);
                    }
                    let mut command = Command::new(backend_exe()?);
                    command
                        .arg("--serve")
                        .env("RUSTSEARCH_DATA_DIR", data_dir()?)
                        .stdin(Stdio::null())
                        .stdout(Stdio::null())
                        .stderr(
                            std::fs::OpenOptions::new()
                                .create(true)
                                .append(true)
                                .open(log)?,
                        )
                        .creation_flags(0x08000000);
                    spawned = Some(command.spawn()?);
                }
            }
            Err(error) => return Err(error.into()),
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    bail!("Shared engine did not start; another legacy backend may hold the index")
}

enum Message {
    Join(u64, mpsc::Sender<Value>),
    Request(u64, bool, Value),
    Leave(u64),
}

pub async fn serve() -> Result<()> {
    let migration = data_dir()?.join(".migration.lock");
    if migration.exists() {
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(migration)
            .context("Data directory is being migrated")?;
    }
    let name = pipe_name()?;
    let first = create_pipe(&name, true)?;
    let (tx, mut rx) = mpsc::channel(128);
    let accept = tokio::spawn(async move {
        let mut listener = first;
        let mut session = 0u64;
        loop {
            listener.connect().await?;
            let connected = listener;
            listener = create_pipe(&name, false)?;
            session += 1;
            let id = session;
            let tx = tx.clone();
            tokio::spawn(async move {
                let (read, mut write) = tokio::io::split(connected);
                let mut lines = BufReader::new(read).lines();
                let hello = tokio::time::timeout(Duration::from_secs(5), lines.next_line()).await;
                let readonly = match hello {
                    Ok(Ok(Some(line))) => match serde_json::from_str::<Value>(&line) {
                        Ok(v)
                            if v["protocol"] == 1
                                && matches!(v["role"].as_str(), Some("mcp" | "desktop")) =>
                        {
                            v["role"] == "mcp"
                        }
                        _ => return,
                    },
                    _ => return,
                };
                let (output, mut responses) = mpsc::channel::<Value>(128);
                if tx.send(Message::Join(id, output)).await.is_err() {
                    return;
                }
                loop {
                    tokio::select! {
                        line = lines.next_line() => {
                            match line {
                                Ok(Some(line)) if line.len() <= 2 * 1024 * 1024 => {
                                    if let Ok(value) = serde_json::from_str(&line) {
                                        if tx.send(Message::Request(id, readonly, value)).await.is_err() { break; }
                                    }
                                }
                                _ => break,
                            }
                        }
                        value = responses.recv() => {
                            let Some(value) = value else { break; };
                            if write.write_all(format!("{value}\n").as_bytes()).await.is_err() { break; }
                        }
                    }
                }
                let _ = tx.send(Message::Leave(id)).await;
            });
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    });
    let mut engine = Command::new(backend_exe()?)
        .env("RUSTSEARCH_DATA_DIR", data_dir()?)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .creation_flags(0x08000000)
        .kill_on_drop(true)
        .spawn()?;
    let mut input = engine.stdin.take().context("Missing engine stdin")?;
    let mut lines = BufReader::new(engine.stdout.take().context("Missing engine stdout")?).lines();
    let mut clients = HashMap::<u64, mpsc::Sender<Value>>::new();
    let mut pending = HashMap::<u64, (u64, Value)>::new();
    let mut sequence = 0u64;
    let mut had_clients = false;
    let mut exclusive = None;
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    loop {
        tokio::select! {
            _ = tick.tick(), if had_clients && clients.is_empty() => break,
            message = rx.recv() => {
                match message {
                    Some(Message::Join(id, out)) => {
                        had_clients = true;
                        if exclusive.is_none() { clients.insert(id, out); }
                    }
                    Some(Message::Leave(id)) => { clients.remove(&id); pending.retain(|_, (session, _)| *session != id); }
                    Some(Message::Request(session, readonly, mut value)) => {
                        let Some(out) = clients.get(&session) else { continue; };
                        let original = value["id"].clone();
                        let method = value["method"].as_str().unwrap_or_default().to_owned();
                        let reply = |code: &str, message: &str| json!({"id":original,"ok":false,"error":{"code":code,"message":message}});
                        if !value.is_object() || !original.is_u64() || method.is_empty() || value.get("params").is_some_and(|v| !v.is_object()) {
                            let _ = out.try_send(reply("INVALID_PARAMS", "Expected numeric id, method and object params")); continue;
                        }
                        if value.get("params").is_none() { value["params"] = json!({}); }
                        if readonly && !matches!(method.as_str(), "search.query" | "doc.preview" | "index.list_roots" | "index.status" | "app.stats") {
                            let _ = out.try_send(reply("ACCESS_DENIED", "MCP sessions are read-only")); continue;
                        }
                        if readonly && method == "search.query" { value["params"]["record_history"] = json!(false); }
                        if readonly && method == "doc.preview" { value["params"]["indexed_only"] = json!(true); }
                        if method == "app.prepare_migration" {
                            if clients.len() != 1 { let _ = out.try_send(reply("INDEX_BUSY", "Close MCP clients before migrating the data directory")); }
                            else { exclusive = Some(session); let _ = out.try_send(json!({"id":original,"ok":true,"result":{"ready":true}})); }
                            continue;
                        }
                        if method == "app.shutdown" {
                            if clients.len() == 1 {
                                input.write_all(b"{\"id\":0,\"method\":\"app.shutdown\",\"params\":{}}\n").await?;
                                while lines.next_line().await?.is_some() {}
                                engine.wait().await?;
                            }
                            let _ = out.send(json!({"id":original,"ok":true,"result":{"shutdown":true}})).await;
                            if clients.len() == 1 { tokio::time::sleep(Duration::from_millis(100)).await; break; }
                            continue;
                        }
                        if pending.len() >= 64 { let _ = out.try_send(reply("INDEX_BUSY", "Shared request queue is full")); continue; }
                        sequence += 1;
                        pending.insert(sequence, (session, original));
                        value["id"] = json!(sequence);
                        input.write_all(format!("{value}\n").as_bytes()).await?;
                    }
                    None => break,
                }
            }
            line = lines.next_line() => {
                let Some(line) = line? else { break; };
                let mut value: Value = serde_json::from_str(&line)?;
                if let Some(id) = value["id"].as_u64() {
                    if let Some((session, original)) = pending.remove(&id) {
                        value["id"] = original;
                        if value["result"].is_object() && value["result"].get("total_docs").is_some() && value["result"].get("roots").is_some() {
                            value["result"]["active_clients"] = json!(clients.len());
                            value["result"]["engine_pid"] = json!(engine.id());
                            value["result"]["data_directory"] = json!(data_dir()?);
                        }
                        if let Some(out) = clients.get(&session) { let _ = out.try_send(value); }
                    }
                } else {
                    for out in clients.values() { let _ = out.try_send(value.clone()); }
                }
            }
        }
    }
    drop(input);
    if tokio::time::timeout(Duration::from_secs(15), engine.wait())
        .await
        .is_err()
    {
        let _ = engine.kill().await;
        let _ = engine.wait().await;
    }
    // Keep the pipe instance reserved until the index writer has released its
    // locks. New clients' readiness probes will retry while we drain.
    accept.abort();
    let _ = accept.await;
    Ok(())
}

pub async fn bridge() -> Result<()> {
    let pipe = connect(false).await?;
    let (read, mut write) = tokio::io::split(pipe);
    let mut responses = BufReader::new(read).lines();
    let mut stdin = BufReader::new(tokio::io::stdin()).lines();
    let mut stdout = tokio::io::stdout();
    let mut shutdown_id = None;
    loop {
        tokio::select! {
            line = stdin.next_line(), if shutdown_id.is_none() => {
                let Some(line) = line? else { break; };
                if let Ok(value) = serde_json::from_str::<Value>(&line) {
                    if value["method"] == "app.shutdown" { shutdown_id = Some(value["id"].clone()); }
                }
                write.write_all(format!("{line}\n").as_bytes()).await?;
            }
            line = responses.next_line() => {
                let Some(line) = line? else { break; };
                stdout.write_all(format!("{line}\n").as_bytes()).await?;
                stdout.flush().await?;
                if shutdown_id.as_ref().is_some_and(|id| serde_json::from_str::<Value>(&line).is_ok_and(|value| value["id"] == *id)) { break; }
            }
        }
    }
    Ok(())
}
