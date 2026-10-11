#![cfg(windows)]
use rmcp::{model::CallToolRequestParams, transport::TokioChildProcess, ServiceExt};
use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
};

fn backend() -> String {
    std::env::var("RUSTSEARCH_TEST_BACKEND")
        .unwrap_or_else(|_| env!("CARGO_BIN_EXE_rustsearch-backend").into())
}
fn mcp() -> String {
    std::env::var("RUSTSEARCH_TEST_MCP")
        .unwrap_or_else(|_| env!("CARGO_BIN_EXE_rustsearch-mcp").into())
}

struct Desktop {
    child: Child,
    input: ChildStdin,
    output: tokio::io::Lines<BufReader<ChildStdout>>,
    id: u64,
}

#[tokio::test]
async fn rapid_desktop_handoff_waits_for_the_previous_engine() {
    let temp = tempfile::tempdir().unwrap();
    for _ in 0..12 {
        let mut desktop = Desktop::start(temp.path());
        assert_eq!(desktop.call("app.stats", json!({})).await["ok"], true);
        // Exercise both abrupt disconnect and an immediate reconnect while
        // the broker is acknowledging graceful shutdown.
        assert_eq!(desktop.call("app.shutdown", json!({})).await["ok"], true);
        let mut next = Desktop::start(temp.path());
        assert_eq!(next.call("app.stats", json!({})).await["ok"], true);
        next.child.kill().await.unwrap();
        next.child.wait().await.unwrap();
    }
}

#[tokio::test]
async fn dead_engine_exits_stdio_bridge_even_with_stdin_open() {
    let temp = tempfile::tempdir().unwrap();
    let mut desktop = Desktop::start(temp.path());
    let stats = desktop.call("app.stats", json!({})).await;
    let pid = stats["result"]["engine_pid"].as_u64().unwrap();
    let status = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/F"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .unwrap();
    assert!(status.success());
    tokio::time::timeout(std::time::Duration::from_secs(10), desktop.child.wait())
        .await
        .expect("bridge must not wait for its frontend to close stdin")
        .unwrap();
    let mut replacement = Desktop::start(temp.path());
    assert_eq!(replacement.call("app.stats", json!({})).await["ok"], true);
    assert_eq!(
        replacement.call("app.shutdown", json!({})).await["ok"],
        true
    );
}
impl Desktop {
    fn start(dir: &std::path::Path) -> Self {
        let mut child = Command::new(backend())
            .arg("--connect")
            .env("RUSTSEARCH_DATA_DIR", dir)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        Self {
            input: child.stdin.take().unwrap(),
            output: BufReader::new(child.stdout.take().unwrap()).lines(),
            child,
            id: 0,
        }
    }
    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.id += 1;
        self.input
            .write_all(
                format!(
                    "{}\n",
                    json!({"id":self.id,"method":method,"params":params})
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
            loop {
                let line = self
                    .output
                    .next_line()
                    .await
                    .unwrap()
                    .expect("Shared bridge disconnected");
                let value: Value = serde_json::from_str(&line).expect("stdout must be JSON");
                if value["id"] == self.id {
                    return value;
                }
            }
        })
        .await
        .unwrap()
    }
}

#[tokio::test]
async fn official_sdk_searches_shared_index_without_writing_history() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().join("data");
    let root = temp.path().join("中文资料");
    std::fs::create_dir(&root).unwrap();
    std::fs::write(
        root.join("采购合同.txt"),
        "合同正文\n甲乙双方签订采购合同。😀",
    )
    .unwrap();
    let mut desktop = Desktop::start(&dir);
    assert_eq!(
        desktop.call("index.add_root", json!({"path":root})).await["ok"],
        true
    );
    for _ in 0..100 {
        if desktop.call("app.stats", json!({})).await["result"]["total_docs"] == 1 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    let client = || {
        let mut command = Command::new(mcp());
        command
            .env("RUSTSEARCH_DATA_DIR", &dir)
            .stderr(std::process::Stdio::null());
        TokioChildProcess::new(command).unwrap()
    };
    let one = ().serve(client()).await.unwrap();
    let two = ().serve(client()).await.unwrap();
    assert_eq!(
        one.peer_info().unwrap().server_info.as_ref().unwrap().name,
        "rustsearch"
    );
    assert_eq!(
        one.peer_info()
            .unwrap()
            .server_info
            .as_ref()
            .unwrap()
            .version,
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(one.list_all_tools().await.unwrap().len(), 5);
    let roots = serde_json::to_value(
        one.call_tool(CallToolRequestParams::new("list_index_roots"))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        roots["structuredContent"]["roots"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        std::fs::canonicalize(
            roots["structuredContent"]["roots"][0]["path"]
                .as_str()
                .unwrap()
        )
        .unwrap(),
        std::fs::canonicalize(&root).unwrap()
    );
    let query = CallToolRequestParams::new("search_files")
        .with_arguments(json!({"query":"采购合同"}).as_object().unwrap().clone());
    let (a, b) = tokio::join!(one.call_tool(query.clone()), two.call_tool(query));
    let a = serde_json::to_value(a.unwrap()).unwrap();
    let b = serde_json::to_value(b.unwrap()).unwrap();
    assert_eq!(a["structuredContent"]["total_hits"], 1, "{a}");
    assert_eq!(b["structuredContent"]["total_hits"], 1, "{b}");
    assert!(!a.to_string().contains("<b>"));
    let one_status = serde_json::to_value(
        one.call_tool(CallToolRequestParams::new("get_index_status"))
            .await
            .unwrap(),
    )
    .unwrap();
    let two_status = serde_json::to_value(
        two.call_tool(CallToolRequestParams::new("get_index_status"))
            .await
            .unwrap(),
    )
    .unwrap();
    let desktop_status = desktop.call("app.stats", json!({})).await;
    assert_eq!(
        one_status["structuredContent"]["engine_pid"],
        desktop_status["result"]["engine_pid"]
    );
    assert_eq!(
        two_status["structuredContent"]["engine_pid"],
        desktop_status["result"]["engine_pid"]
    );
    let invalid = one
        .call_tool(
            CallToolRequestParams::new("search_files").with_arguments(
                json!({"query":"合同","page_size":51})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        )
        .await
        .unwrap();
    assert_eq!(serde_json::to_value(invalid).unwrap()["isError"], true);
    let invalid = one
        .call_tool(
            CallToolRequestParams::new("get_file_preview").with_arguments(
                json!({"document_id":"../../outside.txt"})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        )
        .await
        .unwrap();
    assert_eq!(serde_json::to_value(invalid).unwrap()["isError"], true);
    assert_eq!(
        desktop.call("search.history", json!({})).await["result"]["queries"],
        json!([])
    );
    let id = a["structuredContent"]["hits"][0]["document_id"].clone();
    let preview = one
        .call_tool(
            CallToolRequestParams::new("get_file_preview").with_arguments(
                json!({"document_id":id,"max_chars":4})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        )
        .await
        .unwrap();
    let preview = serde_json::to_value(preview).unwrap();
    assert_eq!(
        preview["structuredContent"]["text"]
            .as_str()
            .unwrap()
            .chars()
            .count(),
        4
    );
    assert_eq!(preview["structuredContent"]["next_offset"], 4);
    if std::env::var_os("RUSTSEARCH_OCR_RUNTIME_DIR").is_some()
        || std::path::Path::new(&backend())
            .parent()
            .unwrap()
            .join("OCR")
            .is_dir()
    {
        assert_eq!(
            desktop
                .call("config.set", json!({"ocr_enabled":true}))
                .await["ok"],
            true
        );
        std::fs::write(
            root.join("scan-图片📄.png"),
            include_bytes!("fixtures/ocr-chinese.png"),
        )
        .unwrap();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
        let image = loop {
            let result = one
                .call_tool(
                    CallToolRequestParams::new("search_files").with_arguments(
                        json!({"query":"采购合同","extensions":["png"]})
                            .as_object()
                            .unwrap()
                            .clone(),
                    ),
                )
                .await
                .unwrap();
            let result = serde_json::to_value(result).unwrap();
            if result["structuredContent"]["total_hits"] == 1 {
                break result;
            }
            if tokio::time::Instant::now() >= deadline {
                let status = desktop.call("app.stats", json!({})).await;
                let log =
                    std::fs::read_to_string(dir.join("logs/shared-engine.log")).unwrap_or_default();
                panic!(
                    "OCR search timed out: {result}; status: {status}; shared engine log: {log}"
                );
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        };
        let id = image["structuredContent"]["hits"][0]["document_id"].clone();
        let page = one
            .call_tool(
                CallToolRequestParams::new("get_document_page").with_arguments(
                    json!({"document_id":id,"page":1})
                        .as_object()
                        .unwrap()
                        .clone(),
                ),
            )
            .await
            .unwrap();
        let page = serde_json::to_value(page).unwrap();
        assert_ne!(page["isError"], true, "{page}");
        assert!(
            page["structuredContent"]["text"]
                .as_str()
                .unwrap()
                .contains("采购合同"),
            "{page}"
        );
    }
    assert_eq!(
        desktop.call("app.prepare_migration", json!({})).await["error"]["code"],
        "INDEX_BUSY"
    );
    assert_eq!(desktop.call("app.shutdown", json!({})).await["ok"], true);
    desktop.child.wait().await.unwrap();
    one.cancel().await.unwrap();
    let status = two
        .call_tool(CallToolRequestParams::new("get_index_status"))
        .await
        .unwrap();
    assert_ne!(serde_json::to_value(status).unwrap()["isError"], true);
    two.cancel().await.unwrap();
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    let mut desktop = Desktop::start(&dir);
    assert_eq!(
        desktop.call("app.prepare_migration", json!({})).await["ok"],
        true
    );
    assert_eq!(desktop.call("app.shutdown", json!({})).await["ok"], true);
    desktop.child.wait().await.unwrap();
}

#[tokio::test]
async fn mcp_session_reconnects_after_shared_engine_crash() {
    let temp = tempfile::tempdir().unwrap();
    let mut command = Command::new(mcp());
    command
        .env("RUSTSEARCH_DATA_DIR", temp.path())
        .stderr(std::process::Stdio::null());
    let client = ().serve(TokioChildProcess::new(command).unwrap()).await.unwrap();
    let status = serde_json::to_value(
        client
            .call_tool(CallToolRequestParams::new("get_index_status"))
            .await
            .unwrap(),
    )
    .unwrap();
    let pid = status["structuredContent"]["engine_pid"].as_u64().unwrap();
    assert!(Command::new("taskkill.exe")
        .args(["/PID", &pid.to_string(), "/F"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .unwrap()
        .success());
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        let status = serde_json::to_value(
            client
                .call_tool(CallToolRequestParams::new("get_index_status"))
                .await
                .unwrap(),
        )
        .unwrap();
        if let Some(replacement) = status["structuredContent"]["engine_pid"].as_u64() {
            if replacement != pid {
                break;
            }
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "MCP did not reconnect: {status}"
        );
    }
    assert_eq!(client.list_all_tools().await.unwrap().len(), 5);
    client.cancel().await.unwrap();
}

#[tokio::test]
async fn legacy_mcp_initialization_accepts_string_ids_and_stays_json_only() {
    let temp = tempfile::tempdir().unwrap();
    let mut child = Command::new(mcp())
        .env("RUSTSEARCH_DATA_DIR", temp.path())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    input.write_all(format!("{}\n",json!({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"compatibility-test","version":"1"}}})).as_bytes()).await.unwrap();
    let line = tokio::time::timeout(std::time::Duration::from_secs(20), lines.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let response: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["id"], "init");
    assert_eq!(
        response["result"]["protocolVersion"], "2024-11-05",
        "{response}"
    );
    input.write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n{\"jsonrpc\":\"2.0\",\"id\":\"tools\",\"method\":\"tools/list\",\"params\":{}}\n").await.unwrap();
    let line = tokio::time::timeout(std::time::Duration::from_secs(20), lines.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let response: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["id"], "tools");
    assert_eq!(response["result"]["tools"].as_array().unwrap().len(), 5);
    drop(input);
    tokio::time::timeout(std::time::Duration::from_secs(10), child.wait())
        .await
        .unwrap()
        .unwrap();
}
