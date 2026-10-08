pub mod protocol;
use serde::Serialize;
use serde_json::Value;
use std::io::{self, Write};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
pub struct Output(Arc<Mutex<io::Stdout>>);
impl Output {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(io::stdout())))
    }
    pub fn send(&self, value: &impl Serialize) {
        if let Ok(mut out) = self.0.lock() {
            let result = serde_json::to_writer(&mut *out, value)
                .map_err(io::Error::other)
                .and_then(|_| out.write_all(b"\n"))
                .and_then(|_| out.flush());
            if let Err(error) = result {
                tracing::error!(%error, "IPC output failed");
            }
        }
    }
    pub fn event(&self, event: &str, data: Value) {
        self.send(&protocol::Event {
            id: None,
            event,
            data,
        });
    }
}
