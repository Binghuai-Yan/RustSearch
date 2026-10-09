mod docx;
mod epub;
mod html;
mod image;
mod pdf;
mod plain_text;
mod pptx;
mod xlsx;
mod xml;

use anyhow::{bail, Result};
use std::path::Path;

pub const MAX_TEXT_SIZE: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ExtractResult {
    pub text: String,
    pub title: Option<String>,
    pub truncated: bool,
    pub needs_ocr: bool,
}

pub fn supported_extension(ext: &str) -> bool {
    matches!(
        ext.to_ascii_lowercase().as_str(),
        "txt"
            | "md"
            | "markdown"
            | "log"
            | "json"
            | "xml"
            | "yaml"
            | "yml"
            | "ini"
            | "csv"
            | "tsv"
            | "toml"
            | "rs"
            | "py"
            | "js"
            | "jsx"
            | "ts"
            | "tsx"
            | "java"
            | "c"
            | "cpp"
            | "cc"
            | "h"
            | "hpp"
            | "cs"
            | "go"
            | "rb"
            | "php"
            | "sh"
            | "bat"
            | "ps1"
            | "sql"
            | "html"
            | "htm"
            | "xhtml"
            | "css"
            | "scss"
            | "vue"
            | "svelte"
            | "pdf"
            | "docx"
            | "xlsx"
            | "xls"
            | "xlsb"
            | "pptx"
            | "epub"
            | "png"
            | "jpg"
            | "jpeg"
            | "bmp"
            | "tif"
            | "tiff"
    )
}

pub fn extract(path: &Path) -> Result<ExtractResult> {
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "pdf" => pdf::extract(path),
        "png" | "jpg" | "jpeg" | "bmp" | "tif" | "tiff" => image::extract(path),
        "docx" => docx::extract(path),
        "xlsx" | "xls" | "xlsb" => xlsx::extract(path),
        "pptx" => pptx::extract(path),
        "html" | "htm" | "xhtml" => html::extract(path),
        "epub" => epub::extract(path),
        _ if supported_extension(&ext) => plain_text::extract(path),
        _ => bail!("unsupported extension: {ext}"),
    }
}

#[derive(Default)]
pub(super) struct TextBuffer {
    pub text: String,
    pub truncated: bool,
}

impl TextBuffer {
    pub fn push(&mut self, value: &str) {
        if value.is_empty() || self.truncated {
            return;
        }
        let available = MAX_TEXT_SIZE.saturating_sub(self.text.len());
        if value.len() <= available {
            self.text.push_str(value);
        } else {
            let mut end = available;
            while !value.is_char_boundary(end) {
                end -= 1;
            }
            self.text.push_str(&value[..end]);
            self.truncated = true;
        }
    }

    pub fn finish(self, title: Option<String>) -> ExtractResult {
        ExtractResult {
            text: self.text,
            title,
            truncated: self.truncated,
            needs_ocr: false,
        }
    }
}

#[cfg(test)]
pub(super) mod tests {
    use std::fs::File;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use zip::{write::FileOptions, ZipWriter};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    pub struct Fixture(pub PathBuf);

    impl Fixture {
        pub fn new(extension: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "rustsearch-extract-{}-{}.{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed),
                extension
            ));
            Self(path)
        }

        pub fn zip(extension: &str, entries: &[(&str, &str)]) -> Self {
            let fixture = Self::new(extension);
            let mut zip = ZipWriter::new(File::create(&fixture.0).unwrap());
            for (name, text) in entries {
                zip.start_file(*name, FileOptions::default()).unwrap();
                zip.write_all(text.as_bytes()).unwrap();
            }
            zip.finish().unwrap();
            fixture
        }

        pub fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    #[test]
    fn truncation_preserves_utf8_boundary() {
        let mut out = super::TextBuffer::default();
        out.push(&"x".repeat(super::MAX_TEXT_SIZE - 2));
        out.push("\u{5408}\u{540c}");
        assert!(out.truncated);
        assert_eq!(out.text.len(), super::MAX_TEXT_SIZE - 2);
    }
}
