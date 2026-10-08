use super::{
    html::extract_html,
    xml::{extract_tag_text, Archive},
    ExtractResult, TextBuffer,
};
use anyhow::{bail, Context, Result};
use quick_xml::{
    events::{BytesStart, Event},
    Reader,
};
use std::collections::HashMap;
use std::path::Path;

pub fn extract(path: &Path) -> Result<ExtractResult> {
    let mut archive = Archive::open(path)?;
    let container = archive.read("META-INF/container.xml")?;
    let package_path = find_package(&container)?.context("EPUB has no rootfile")?;
    let package = archive.read(&package_path)?;
    let (title, chapters) = read_package(&package)?;
    let parent = package_path
        .rsplit_once('/')
        .map(|(parent, _)| parent)
        .unwrap_or("");
    let mut text = TextBuffer::default();
    for chapter in chapters {
        let name = resolve_archive_path(parent, chapter.split('#').next().unwrap_or(&chapter))?;
        let bytes = archive.read(&name)?;
        let decoded = String::from_utf8_lossy(&bytes);
        let chapter = extract_html(&decoded);
        text.push(&chapter.text);
        text.push("\n\n");
        text.truncated |= chapter.truncated;
        if text.truncated {
            break;
        }
    }
    Ok(text.finish(title))
}

fn attr(event: &BytesStart<'_>, name: &[u8], reader: &Reader<&[u8]>) -> Result<Option<String>> {
    for attribute in event.attributes() {
        let attribute = attribute?;
        if attribute.key.local_name().as_ref() == name {
            return Ok(Some(
                attribute.decode_and_unescape_value(reader)?.into_owned(),
            ));
        }
    }
    Ok(None)
}

fn find_package(bytes: &[u8]) -> Result<Option<String>> {
    let mut reader = Reader::from_reader(bytes);
    loop {
        match reader.read_event()? {
            Event::Start(event) | Event::Empty(event)
                if event.local_name().as_ref() == b"rootfile" =>
            {
                if let Some(path) = attr(&event, b"full-path", &reader)? {
                    return Ok(Some(resolve_archive_path("", &path)?));
                }
            }
            Event::Eof => return Ok(None),
            _ => {}
        }
    }
}

fn read_package(bytes: &[u8]) -> Result<(Option<String>, Vec<String>)> {
    let mut title = TextBuffer::default();
    extract_tag_text(bytes, b"title", None, &mut title)?;
    let title = if title.text.trim().is_empty() {
        None
    } else {
        Some(title.text.trim().chars().take(2048).collect())
    };
    let mut reader = Reader::from_reader(bytes);
    let mut manifest = HashMap::new();
    let mut spine = Vec::new();
    loop {
        match reader.read_event()? {
            Event::Start(event) | Event::Empty(event) => match event.local_name().as_ref() {
                b"item" => {
                    if let (Some(id), Some(href), Some(media_type)) = (
                        attr(&event, b"id", &reader)?,
                        attr(&event, b"href", &reader)?,
                        attr(&event, b"media-type", &reader)?,
                    ) {
                        if matches!(media_type.as_str(), "application/xhtml+xml" | "text/html") {
                            manifest.insert(id, href);
                        }
                    }
                }
                b"itemref" => {
                    if let Some(idref) = attr(&event, b"idref", &reader)? {
                        spine.push(idref);
                    }
                }
                _ => {}
            },
            Event::Eof => break,
            _ => {}
        }
    }
    let chapters: Vec<String> = spine
        .into_iter()
        .filter_map(|id| manifest.remove(&id))
        .collect();
    if chapters.is_empty() {
        bail!("EPUB has no readable chapters in its spine");
    }
    Ok((title, chapters))
}

fn resolve_archive_path(parent: &str, reference: &str) -> Result<String> {
    if reference.contains(':') || reference.starts_with('/') || reference.contains('\\') {
        bail!("invalid EPUB archive reference");
    }
    let mut parts: Vec<&str> = parent.split('/').filter(|part| !part.is_empty()).collect();
    for part in reference.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    bail!("EPUB reference escapes archive root");
                }
            }
            value => parts.push(value),
        }
    }
    Ok(parts.join("/"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn archive_paths_stay_inside_document() {
        assert_eq!(
            super::resolve_archive_path("OEBPS/Text", "../chapter.xhtml").unwrap(),
            "OEBPS/chapter.xhtml"
        );
        assert!(super::resolve_archive_path("OEBPS", "../../secret").is_err());
        assert!(super::resolve_archive_path("", "https://example.com/").is_err());
    }

    #[test]
    fn chinese_epub_uses_reading_order() {
        let fixture = super::super::tests::Fixture::zip("epub", &[
            ("META-INF/container.xml", "<container><rootfiles><rootfile full-path='OEBPS/book.opf'/></rootfiles></container>"),
            ("OEBPS/book.opf", "<package xmlns:dc='urn:dc'><metadata><dc:title>\u{4e2d}\u{6587}\u{4e66}\u{7c4d}</dc:title></metadata><manifest><item id='a' href='z.xhtml' media-type='application/xhtml+xml'/><item id='b' href='a.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>"),
            ("OEBPS/z.xhtml", "<html><body><p>\u{7b2c}\u{4e00}\u{7ae0}\u{5408}\u{540c}</p></body></html>"),
            ("OEBPS/a.xhtml", "<html><body><p>\u{7b2c}\u{4e8c}\u{7ae0}\u{6761}\u{6b3e}</p></body></html>"),
        ]);
        let result = super::extract(fixture.path()).unwrap();
        assert_eq!(
            result.title.as_deref(),
            Some("\u{4e2d}\u{6587}\u{4e66}\u{7c4d}")
        );
        assert!(
            result.text.find("\u{7b2c}\u{4e00}\u{7ae0}").unwrap()
                < result.text.find("\u{7b2c}\u{4e8c}\u{7ae0}").unwrap()
        );
    }
}
