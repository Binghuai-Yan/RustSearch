use super::{
    xml::{extract_tag_text, Archive},
    ExtractResult, TextBuffer,
};
use anyhow::Result;
use std::path::Path;

pub fn extract(path: &Path) -> Result<ExtractResult> {
    let mut archive = Archive::open(path)?;
    let title = archive.title();
    let document = archive.read("word/document.xml")?;
    let mut text = TextBuffer::default();
    extract_tag_text(&document, b"t", Some(b"p"), &mut text)?;
    Ok(text.finish(title))
}

#[cfg(test)]
mod tests {
    #[test]
    fn chinese_paragraphs_and_title() {
        let fixture = super::super::tests::Fixture::zip("docx", &[
            ("word/document.xml", "<w:document xmlns:w='urn:w'><w:body><w:p><w:r><w:t>\u{5408}\u{540c}&amp;\u{6761}\u{6b3e}</w:t><w:tab/><w:t>2026</w:t></w:r></w:p><w:p><w:r><w:t>\u{7b2c}\u{4e8c}\u{6bb5}</w:t></w:r></w:p></w:body></w:document>"),
            ("docProps/core.xml", "<cp:coreProperties xmlns:cp='urn:cp' xmlns:dc='urn:dc'><dc:title>\u{91c7}\u{8d2d}\u{5408}\u{540c}</dc:title></cp:coreProperties>"),
        ]);
        let result = super::extract(fixture.path()).unwrap();
        assert_eq!(
            result.text,
            "\u{5408}\u{540c}&\u{6761}\u{6b3e}\t2026\n\u{7b2c}\u{4e8c}\u{6bb5}\n"
        );
        assert_eq!(
            result.title.as_deref(),
            Some("\u{91c7}\u{8d2d}\u{5408}\u{540c}")
        );
    }

    #[test]
    fn invalid_xml_is_an_error() {
        let fixture = super::super::tests::Fixture::zip(
            "docx",
            &[("word/document.xml", "<document><t>bad</x></document>")],
        );
        assert!(super::extract(fixture.path()).is_err());
    }
}
