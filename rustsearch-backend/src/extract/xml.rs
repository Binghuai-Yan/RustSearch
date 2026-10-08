use super::TextBuffer;
use anyhow::{bail, Context, Result};
use quick_xml::{events::Event, Reader};
use std::fs::File;
use std::io::Read;
use std::path::Path;
use zip::ZipArchive;

const MAX_XML_BYTES: u64 = 32 * 1024 * 1024;
const MAX_ARCHIVE_XML_BYTES: u64 = 128 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES: usize = 20_000;

pub(super) struct Archive {
    zip: ZipArchive<File>,
    decoded_bytes: u64,
}

impl Archive {
    pub fn open(path: &Path) -> Result<Self> {
        let zip = ZipArchive::new(File::open(path)?)
            .with_context(|| format!("invalid document archive: {}", path.display()))?;
        if zip.len() > MAX_ARCHIVE_ENTRIES {
            bail!("document archive has too many entries");
        }
        Ok(Self {
            zip,
            decoded_bytes: 0,
        })
    }

    pub fn names(&self) -> Vec<String> {
        self.zip.file_names().map(str::to_owned).collect()
    }

    pub fn read(&mut self, name: &str) -> Result<Vec<u8>> {
        let file = self
            .zip
            .by_name(name)
            .with_context(|| format!("missing archive entry: {name}"))?;
        if file.size() > MAX_XML_BYTES {
            bail!("archive entry exceeds 32 MiB: {name}");
        }
        let remaining = MAX_ARCHIVE_XML_BYTES.saturating_sub(self.decoded_bytes);
        if file.size() > remaining {
            bail!("document XML exceeds 128 MiB extraction limit");
        }
        let read_limit = remaining.min(MAX_XML_BYTES);
        let mut data = Vec::with_capacity(file.size().min(1024 * 1024) as usize);
        file.take(read_limit + 1).read_to_end(&mut data)?;
        if data.len() as u64 > read_limit {
            bail!("archive entry exceeds extraction limit: {name}");
        }
        self.decoded_bytes += data.len() as u64;
        Ok(data)
    }

    pub fn title(&mut self) -> Option<String> {
        let bytes = self.read("docProps/core.xml").ok()?;
        let mut text = TextBuffer::default();
        extract_tag_text(&bytes, b"title", None, &mut text).ok()?;
        let title = text.text.trim();
        if title.is_empty() {
            None
        } else {
            Some(title.chars().take(2048).collect())
        }
    }
}

pub(super) fn extract_tag_text(
    bytes: &[u8],
    text_tag: &[u8],
    paragraph_tag: Option<&[u8]>,
    out: &mut TextBuffer,
) -> Result<()> {
    let mut reader = Reader::from_reader(bytes);
    reader.trim_text(false);
    let mut buffer = Vec::new();
    let mut text_depth = 0usize;
    loop {
        match reader
            .read_event_into(&mut buffer)
            .context("invalid document XML")?
        {
            Event::Start(event) => {
                if event.local_name().as_ref() == text_tag {
                    text_depth += 1;
                }
                if event.local_name().as_ref() == b"tab" {
                    out.push("\t");
                }
                if event.local_name().as_ref() == b"br" {
                    out.push("\n");
                }
            }
            Event::Empty(event) => match event.local_name().as_ref() {
                b"tab" => out.push("\t"),
                b"br" => out.push("\n"),
                _ => {}
            },
            Event::Text(event) if text_depth > 0 => out.push(&event.unescape()?),
            Event::CData(event) if text_depth > 0 => out.push(&String::from_utf8_lossy(&event)),
            Event::End(event) => {
                if event.local_name().as_ref() == text_tag {
                    text_depth = text_depth.saturating_sub(1);
                }
                if paragraph_tag == Some(event.local_name().as_ref()) {
                    out.push("\n");
                }
            }
            Event::Eof => break,
            _ => {}
        }
        if out.truncated {
            break;
        }
        buffer.clear();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    #[test]
    fn archive_expansion_is_bounded() {
        let fixture = super::super::tests::Fixture::new("docx");
        let mut zip = zip::ZipWriter::new(std::fs::File::create(fixture.path()).unwrap());
        zip.start_file(
            "word/document.xml",
            zip::write::FileOptions::default().compression_method(zip::CompressionMethod::Deflated),
        )
        .unwrap();
        let block = vec![b'x'; 1024 * 1024];
        for _ in 0..33 {
            zip.write_all(&block).unwrap();
        }
        zip.finish().unwrap();
        let mut archive = super::Archive::open(fixture.path()).unwrap();
        assert!(archive
            .read("word/document.xml")
            .unwrap_err()
            .to_string()
            .contains("32 MiB"));
    }
}
