use super::{ExtractResult, TextBuffer};
use anyhow::{Context, Result};
use lopdf::{Document, Object};
use std::path::Path;

struct LimitedOutput<'a>(&'a mut TextBuffer);

impl std::fmt::Write for LimitedOutput<'_> {
    fn write_str(&mut self, text: &str) -> std::fmt::Result {
        self.0.push(text);
        if self.0.truncated {
            Err(std::fmt::Error)
        } else {
            Ok(())
        }
    }
}

impl<'a> pdf_extract::ConvertToFmt for LimitedOutput<'a> {
    type Writer = Self;
    fn convert(self) -> Self::Writer {
        self
    }
}

pub fn extract(path: &Path) -> Result<ExtractResult> {
    let mut document = Document::load(path).context("cannot open PDF")?;
    if document.is_encrypted() {
        document
            .decrypt("")
            .context("encrypted PDF requires a password")?;
    }
    let title = document.trailer.get(b"Info").ok().and_then(|info| {
        let info = match info {
            Object::Reference(id) => document.get_object(*id).ok()?.as_dict().ok()?,
            Object::Dictionary(info) => info,
            _ => return None,
        };
        let bytes = info.get(b"Title").ok()?.as_str().ok()?;
        let text = if bytes.starts_with(&[0xfe, 0xff]) {
            let (decoded, _) = encoding_rs::UTF_16BE.decode_without_bom_handling(&bytes[2..]);
            decoded.into_owned()
        } else if bytes.starts_with(&[0xff, 0xfe]) {
            let (decoded, _) = encoding_rs::UTF_16LE.decode_without_bom_handling(&bytes[2..]);
            decoded.into_owned()
        } else {
            String::from_utf8_lossy(bytes).into_owned()
        };
        let title: String = text.trim().chars().take(2048).collect();
        if title.is_empty() {
            None
        } else {
            Some(title)
        }
    });
    let mut text = TextBuffer::default();
    // lopdf 0.32 cannot decode Identity-H; pdf-extract handles the PDF's ToUnicode mapping.
    let extraction = {
        let mut output = pdf_extract::PlainTextOutput::new(LimitedOutput(&mut text));
        pdf_extract::output_doc(&document, &mut output)
    };
    if !text.truncated {
        extraction.context("cannot extract PDF text")?;
    }
    let needs_ocr = text.text.trim().is_empty();
    let mut result = text.finish(title);
    result.needs_ocr = needs_ocr;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use lopdf::{
        content::{Content, Operation},
        dictionary, Document, Object, Stream,
    };

    fn create_pdf(text: Option<&str>) -> super::super::tests::Fixture {
        let fixture = super::super::tests::Fixture::new("pdf");
        let mut document = Document::with_version("1.5");
        let pages_id = document.new_object_id();
        let font_id = document.add_object(dictionary! {
            "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica", "Encoding" => "WinAnsiEncoding"
        });
        let resources_id =
            document.add_object(dictionary! { "Font" => dictionary! { "F1" => font_id } });
        let operations = text
            .map(|text| {
                vec![
                    Operation::new("BT", vec![]),
                    Operation::new("Tf", vec![Object::Name(b"F1".to_vec()), 12.into()]),
                    Operation::new("Td", vec![20.into(), 100.into()]),
                    Operation::new("Tj", vec![Object::string_literal(text)]),
                    Operation::new("ET", vec![]),
                ]
            })
            .unwrap_or_default();
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
        let catalog_id =
            document.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
        document.trailer.set("Root", catalog_id);
        document.save(fixture.path()).unwrap();
        fixture
    }

    #[test]
    fn pdf_text_and_no_text_layer() {
        let fixture = create_pdf(Some("Contract 2026"));
        let result = super::extract(fixture.path()).unwrap();
        assert!(result.text.contains("Contract 2026"));
        assert!(!result.needs_ocr);
        let fixture = create_pdf(None);
        assert!(super::extract(fixture.path()).unwrap().needs_ocr);
    }

    #[test]
    fn chinese_pdf_tounicode_mapping() {
        let fixture = super::super::tests::Fixture::new("pdf");
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
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec![Object::Name(b"F1".to_vec()), 12.into()]),
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
        let catalog_id =
            document.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
        document.trailer.set("Root", catalog_id);
        document.save(fixture.path()).unwrap();
        let result = super::extract(fixture.path()).unwrap();
        assert!(result.text.contains("\u{5408}\u{540c}"), "{}", result.text);
    }

    #[test]
    fn pdf_text_writer_stops_at_utf8_limit() {
        use std::fmt::Write;
        let mut text = super::TextBuffer::default();
        text.push(&"x".repeat(super::super::MAX_TEXT_SIZE - 1));
        assert!(super::LimitedOutput(&mut text)
            .write_str("\u{5408}\u{540c}")
            .is_err());
        assert!(text.truncated);
        assert_eq!(text.text.len(), super::super::MAX_TEXT_SIZE - 1);
    }
}
