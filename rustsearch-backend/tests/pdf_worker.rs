use lopdf::{
    content::{Content, Operation},
    dictionary, Document, Object, Stream,
};
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    path::Path,
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const BACKEND: &str = env!("CARGO_BIN_EXE_rustsearch-backend");
const TIMEOUT: Duration = Duration::from_secs(25);
const CHINESE: &str = "\u{5408}\u{540c}";

fn chinese_pdf(path: &Path) {
    let mut document = Document::with_version("1.5");
    let pages_id = document.new_object_id();
    let cmap = b"/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def /CMapName /Adobe-Identity-UCS def /CMapType 2 def 1 begincodespacerange <0000> <FFFF> endcodespacerange 2 beginbfchar <0001> <5408> <0002> <540C> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end";
    let cmap_id = document.add_object(Stream::new(dictionary! {}, cmap.to_vec()));
    let descriptor_id = document.add_object(dictionary! {
        "Type" => "FontDescriptor", "FontName" => "TestChinese", "Flags" => 4,
        "FontBBox" => vec![0.into(), (-120).into(), 1000.into(), 880.into()],
        "ItalicAngle" => 0, "Ascent" => 880, "Descent" => -120, "CapHeight" => 700, "StemV" => 80
    });
    let descendant_id = document.add_object(dictionary! {
        "Type" => "Font", "Subtype" => "CIDFontType2", "BaseFont" => "TestChinese",
        "FontDescriptor" => descriptor_id,
        "CIDSystemInfo" => dictionary! { "Registry" => Object::string_literal("Adobe"), "Ordering" => Object::string_literal("Identity"), "Supplement" => 0 }
    });
    let font_id = document.add_object(dictionary! {
        "Type" => "Font", "Subtype" => "Type0", "BaseFont" => "TestChinese", "Encoding" => "Identity-H",
        "DescendantFonts" => vec![Object::Reference(descendant_id)], "ToUnicode" => cmap_id
    });
    let resources_id =
        document.add_object(dictionary! { "Font" => dictionary! { "F1" => font_id } });
    let operations = vec![
        // This tolerated unmatched restore makes pdf-extract emit its own stdout diagnostic.
        Operation::new("Q", vec![]),
        Operation::new("BT", vec![]),
        Operation::new("Tf", vec![Object::Name(b"F1".to_vec()), 12.into()]),
        Operation::new("Td", vec![20.into(), 100.into()]),
        Operation::new(
            "Tj",
            vec![Object::String(
                vec![0, 1, 0, 2],
                lopdf::StringFormat::Hexadecimal,
            )],
        ),
        Operation::new("ET", vec![]),
    ];
    let content_id = document.add_object(Stream::new(
        dictionary! {},
        Content { operations }.encode().unwrap(),
    ));
    let page_id = document.add_object(dictionary! {
        "Type" => "Page", "Parent" => pages_id, "Contents" => content_id, "Resources" => resources_id,
        "MediaBox" => vec![0.into(), 0.into(), 200.into(), 200.into()]
    });
    document.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages", "Kids" => vec![Object::Reference(page_id)], "Count" => 1
        }),
    );
    let catalog_id = document.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    document.trailer.set("Root", catalog_id);
    document.save(path).unwrap();
}

struct ProcessGuard(Child);

impl ProcessGuard {
    fn wait_success(&mut self) {
        let deadline = Instant::now() + TIMEOUT;
        loop {
            if let Some(status) = self.0.try_wait().unwrap() {
                assert!(status.success(), "backend failed: {status}");
                return;
            }
            assert!(Instant::now() < deadline, "backend timed out");
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for ProcessGuard {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}

struct IpcProcess {
    process: ProcessGuard,
    stdin: Option<ChildStdin>,
    messages: Receiver<Result<Value, String>>,
    received: Vec<Value>,
    reader: Option<JoinHandle<()>>,
}

impl IpcProcess {
    fn start(data_dir: &Path) -> Self {
        let mut child = Command::new(BACKEND)
            .env("RUSTSEARCH_DATA_DIR", data_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().unwrap();
        let (sender, messages) = mpsc::channel();
        let reader = thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let result = line.map_err(|error| error.to_string()).and_then(|line| {
                    serde_json::from_str::<Value>(&line)
                        .map_err(|error| format!("non-JSON protocol output {line:?}: {error}"))
                });
                if sender.send(result).is_err() {
                    break;
                }
            }
        });
        Self {
            process: ProcessGuard(child),
            stdin,
            messages,
            received: vec![],
            reader: Some(reader),
        }
    }

    fn receive_until(&mut self, predicate: impl Fn(&Value) -> bool) -> Value {
        if let Some(message) = self.received.iter().find(|message| predicate(message)) {
            return message.clone();
        }
        let deadline = Instant::now() + TIMEOUT;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let message = self
                .messages
                .recv_timeout(remaining)
                .unwrap_or_else(|error| {
                    panic!(
                        "protocol timed out/disconnected: {error}; received {:?}",
                        self.received
                    )
                })
                .unwrap_or_else(|error| panic!("{error}"));
            assert!(
                message.is_object() && message.get("id").is_some(),
                "invalid protocol envelope: {message}"
            );
            let matched = predicate(&message);
            self.received.push(message.clone());
            if matched {
                return message;
            }
        }
    }

    fn call(&mut self, id: u64, method: &str, params: Value) -> Value {
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(
            stdin,
            "{}",
            json!({"id":id,"method":method,"params":params})
        )
        .unwrap();
        stdin.flush().unwrap();
        let response = self.receive_until(|message| message["id"] == id);
        assert_eq!(response["ok"], true, "request failed: {response}");
        response["result"].clone()
    }

    fn shutdown(mut self) {
        assert_eq!(self.call(99, "app.shutdown", json!({}))["shutdown"], true);
        self.stdin.take();
        self.process.wait_success();
        self.reader.take().unwrap().join().unwrap();
        for message in self.messages.try_iter() {
            let message = message.unwrap_or_else(|error| panic!("{error}"));
            assert!(
                message.is_object() && message.get("id").is_some(),
                "invalid protocol envelope: {message}"
            );
        }
    }
}

#[test]
fn pdf_worker_writes_chinese_to_its_result_file() {
    let fixture = tempfile::tempdir().unwrap();
    let path = fixture.path().join("contract.pdf");
    let output = fixture.path().join("result.json");
    chinese_pdf(&path);
    let mut worker = ProcessGuard(
        Command::new(BACKEND)
            .arg("--extract-one")
            .arg(&path)
            .arg(&output)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    worker.wait_success();
    let result: Value = serde_json::from_slice(&std::fs::read(output).unwrap()).unwrap();
    assert!(result["text"].as_str().unwrap().contains(CHINESE));
    assert_eq!(result["needs_ocr"], false);
    assert_eq!(result["truncated"], false);
}

#[test]
fn pdf_index_search_and_preview_keep_stdout_json_only() {
    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path().join("documents");
    std::fs::create_dir(&root).unwrap();
    let path = root.join("contract.pdf");
    chinese_pdf(&path);
    let mut backend = IpcProcess::start(&fixture.path().join("data"));
    backend.receive_until(|message| {
        message["event"] == "index.finished" && message["data"]["root"] == ""
    });
    let added = backend.call(1, "index.add_root", json!({"path":root}));
    let indexed_root = added["root"].as_str().unwrap();
    let finished = backend.receive_until(|message| {
        message["event"] == "index.finished" && message["data"]["root"] == indexed_root
    });
    assert_eq!(finished["data"]["total_docs"], 1);
    assert_eq!(finished["data"]["failed"], 0);
    let result = backend.call(
        2,
        "search.query",
        json!({"query":CHINESE,"ext":["pdf"],"page":0,"page_size":50,"sort":"relevance"}),
    );
    assert_eq!(result["total_hits"], 1);
    assert_eq!(result["hits"][0]["filename"], "contract.pdf");
    assert!(result["hits"][0]["snippets"]
        .as_array()
        .unwrap()
        .iter()
        .any(|snippet| snippet
            .as_str()
            .unwrap()
            .contains(&format!("<b>{CHINESE}</b>"))));
    let preview = backend.call(3, "doc.preview", json!({"path":path}));
    assert!(preview["text"].as_str().unwrap().contains(CHINESE));
    assert_eq!(preview["needs_ocr"], false);
    backend.shutdown();
}
