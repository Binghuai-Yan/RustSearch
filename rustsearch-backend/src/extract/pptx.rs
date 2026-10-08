use super::{
    xml::{extract_tag_text, Archive},
    ExtractResult, TextBuffer,
};
use anyhow::Result;
use std::path::Path;

pub fn extract(path: &Path) -> Result<ExtractResult> {
    let mut archive = Archive::open(path)?;
    let title = archive.title();
    let mut slides: Vec<(u32, String)> = archive
        .names()
        .into_iter()
        .filter_map(|name| {
            let number = name
                .strip_prefix("ppt/slides/slide")?
                .strip_suffix(".xml")?
                .parse()
                .ok()?;
            Some((number, name))
        })
        .collect();
    slides.sort_by_key(|(number, _)| *number);
    let mut text = TextBuffer::default();
    for (_, name) in slides {
        extract_tag_text(&archive.read(&name)?, b"t", Some(b"p"), &mut text)?;
        text.push("\n");
        if text.truncated {
            break;
        }
    }
    Ok(text.finish(title))
}

#[cfg(test)]
mod tests {
    #[test]
    fn chinese_slides_in_numeric_order() {
        let fixture = super::super::tests::Fixture::zip("pptx", &[
            ("ppt/slides/slide10.xml", "<p:sld xmlns:p='urn:p' xmlns:a='urn:a'><a:p><a:r><a:t>\u{7b2c}\u{5341}\u{9875}</a:t></a:r></a:p></p:sld>"),
            ("ppt/slides/slide2.xml", "<p:sld xmlns:p='urn:p' xmlns:a='urn:a'><a:p><a:r><a:t>\u{7b2c}\u{4e8c}\u{9875}</a:t></a:r></a:p></p:sld>"),
        ]);
        assert_eq!(
            super::extract(fixture.path()).unwrap().text,
            "\u{7b2c}\u{4e8c}\u{9875}\n\n\u{7b2c}\u{5341}\u{9875}\n\n"
        );
    }
}
