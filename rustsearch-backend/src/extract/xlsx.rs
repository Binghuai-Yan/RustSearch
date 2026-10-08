use super::{ExtractResult, TextBuffer};
use anyhow::{bail, Context, Result};
use calamine::{open_workbook_auto, Reader};
use quick_xml::{events::Event, Reader as XmlReader};
use std::path::Path;

pub fn extract(path: &Path) -> Result<ExtractResult> {
    // Calamine materializes worksheets. Reject extreme ZIP expansion before opening OOXML.
    if path
        .extension()
        .and_then(|s| s.to_str())
        .is_some_and(|s| s.eq_ignore_ascii_case("xlsx") || s.eq_ignore_ascii_case("xlsb"))
    {
        let file = std::fs::File::open(path)?;
        let mut archive = zip::ZipArchive::new(file)?;
        if archive.len() > 20_000 {
            bail!("workbook has too many archive entries");
        }
        let mut unpacked = 0u64;
        for i in 0..archive.len() {
            unpacked = unpacked
                .checked_add(archive.by_index(i)?.size())
                .context("workbook size overflow")?;
            if unpacked > 128 * 1024 * 1024 {
                bail!("workbook exceeds 128 MiB decompression limit");
            }
        }
        if path
            .extension()
            .and_then(|s| s.to_str())
            .is_some_and(|s| s.eq_ignore_ascii_case("xlsx"))
        {
            let mut archive = super::xml::Archive::open(path)?;
            for name in archive.names() {
                if name.starts_with("xl/worksheets/")
                    && name.ends_with(".xml")
                    && !name.contains("/_rels/")
                {
                    validate_cell_span(&archive.read(&name)?)?;
                }
            }
        }
    }
    let mut workbook = open_workbook_auto(path).context("cannot open workbook")?;
    let mut text = TextBuffer::default();
    for name in workbook.sheet_names().to_owned() {
        text.push(&name);
        text.push("\n");
        let range = workbook
            .worksheet_range(&name)
            .with_context(|| format!("cannot read worksheet: {name}"))?;
        for row in range.rows() {
            for (column, cell) in row.iter().enumerate() {
                if column > 0 {
                    text.push("\t");
                }
                text.push(&cell.to_string());
                if text.truncated {
                    return Ok(text.finish(None));
                }
            }
            text.push("\n");
            if text.truncated {
                return Ok(text.finish(None));
            }
        }
    }
    Ok(text.finish(None))
}

fn validate_cell_span(bytes: &[u8]) -> Result<()> {
    let mut reader = XmlReader::from_reader(bytes);
    let (mut min_row, mut min_col) = (u64::MAX, u64::MAX);
    let (mut max_row, mut max_col) = (0u64, 0u64);
    let mut count = 0u64;
    loop {
        match reader.read_event()? {
            Event::Start(event) | Event::Empty(event) if event.local_name().as_ref() == b"c" => {
                count += 1;
                if count > 2_000_000 {
                    bail!("worksheet exceeds two million cells");
                }
                for attribute in event.attributes() {
                    let attribute = attribute?;
                    if attribute.key.local_name().as_ref() != b"r" {
                        continue;
                    }
                    let address = attribute.decode_and_unescape_value(&reader)?;
                    let mut column = 0u64;
                    let mut digits_at = 0;
                    for byte in address.bytes() {
                        if !byte.is_ascii_alphabetic() {
                            break;
                        }
                        column = column
                            .checked_mul(26)
                            .and_then(|column| {
                                column.checked_add((byte.to_ascii_uppercase() - b'A' + 1) as u64)
                            })
                            .context("invalid worksheet cell address")?;
                        digits_at += 1;
                    }
                    let row: u64 = address[digits_at..]
                        .parse()
                        .context("invalid worksheet cell address")?;
                    if row == 0 || row > 1_048_576 || column == 0 || column > 16_384 {
                        bail!("worksheet cell outside Excel limits");
                    }
                    min_row = min_row.min(row);
                    max_row = max_row.max(row);
                    min_col = min_col.min(column);
                    max_col = max_col.max(column);
                    // A pair of distant cells can make Calamine allocate an enormous dense range.
                    if (max_row - min_row + 1) * (max_col - min_col + 1) > 2_000_000 {
                        bail!("worksheet cell span exceeds two million cells");
                    }
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn sparse_sheet_cannot_allocate_an_unbounded_range() {
        assert!(super::validate_cell_span(
            b"<worksheet><c r='A1'/><c r='XFD1048576'/></worksheet>"
        )
        .is_err());
        assert!(super::validate_cell_span(
            b"<worksheet><c r='Z99999'/><c r='AA100000'/></worksheet>"
        )
        .is_ok());
    }

    #[test]
    fn chinese_workbook_cells() {
        let fixture = super::super::tests::Fixture::zip("xlsx", &[
            ("[Content_Types].xml", "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Override PartName='/xl/workbook.xml' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml'/></Types>"),
            ("_rels/.rels", "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='xl/workbook.xml'/></Relationships>"),
            ("xl/workbook.xml", "<workbook xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main' xmlns:r='http://schemas.openxmlformats.org/officeDocument/2006/relationships'><sheets><sheet name='\u{5408}\u{540c}\u{5217}\u{8868}' sheetId='1' r:id='rId1'/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet' Target='worksheets/sheet1.xml'/></Relationships>"),
            ("xl/worksheets/sheet1.xml", "<worksheet xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><sheetData><row r='1'><c r='A1' t='inlineStr'><is><t>\u{91c7}\u{8d2d}\u{5408}\u{540c}</t></is></c><c r='B1'><v>2026</v></c></row></sheetData></worksheet>"),
        ]);
        let result = super::extract(fixture.path()).unwrap();
        assert!(result.text.contains("\u{5408}\u{540c}\u{5217}\u{8868}"));
        assert!(result
            .text
            .contains("\u{91c7}\u{8d2d}\u{5408}\u{540c}\t2026"));
    }
}
