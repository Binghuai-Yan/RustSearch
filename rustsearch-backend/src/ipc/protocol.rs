use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: u64,
    pub method: String,
    #[serde(default = "empty_params")]
    pub params: Value,
}

fn empty_params() -> Value {
    serde_json::json!({})
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub id: Option<u64>,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RpcError {
    pub code: &'static str,
    pub message: String,
}

impl Response {
    pub fn success(id: u64, result: Value) -> Self {
        Self {
            id: Some(id),
            ok: true,
            result: Some(result),
            error: None,
        }
    }
    pub fn failure(id: Option<u64>, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            id,
            ok: false,
            result: None,
            error: Some(RpcError {
                code,
                message: message.into(),
            }),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Event<'a> {
    pub id: Option<u64>,
    pub event: &'a str,
    pub data: Value,
}

#[derive(Debug, Deserialize)]
pub struct PathParams {
    pub path: String,
}
#[derive(Debug, Deserialize)]
pub struct RebuildParams {
    pub root: String,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct SearchParams {
    pub query: String,
    pub ext: Vec<String>,
    pub page: usize,
    pub page_size: usize,
    pub sort: String,
}
impl Default for SearchParams {
    fn default() -> Self {
        Self {
            query: String::new(),
            ext: vec![],
            page: 0,
            page_size: 50,
            sort: "relevance".into(),
        }
    }
}
#[derive(Debug, Clone, Serialize)]
pub struct SearchHit {
    pub path: String,
    pub filename: String,
    pub filename_hl: String,
    pub ext: String,
    pub size: u64,
    pub mtime: u64,
    pub score: f32,
    pub snippets: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ocr_page: Option<u32>,
}
#[derive(Debug, Clone, Serialize)]
pub struct SearchResult {
    pub total_hits: usize,
    pub elapsed_ms: u128,
    pub hits: Vec<SearchHit>,
    pub page: usize,
    pub page_size: usize,
}
#[derive(Debug, Serialize)]
pub struct IndexProgress {
    pub root: String,
    pub total: usize,
    pub done: usize,
    pub failed: usize,
    pub current_file: String,
}
#[derive(Debug, Serialize)]
pub struct IndexFinished {
    pub root: String,
    pub total_docs: usize,
    pub failed: usize,
    pub elapsed_s: f64,
}
#[derive(Debug, Default, Serialize)]
pub struct WatcherChange {
    pub added: usize,
    pub modified: usize,
    pub removed: usize,
}
