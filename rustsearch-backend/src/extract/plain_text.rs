use super::{ExtractResult, TextBuffer, MAX_TEXT_SIZE};
use anyhow::{Context, Result};
use chardetng::EncodingDetector;
use encoding_rs::{GB18030, UTF_16BE, UTF_16LE, UTF_8};
use std::fs::File;
use std::io::Read;
use std::path::Path;

pub fn extract(path: &Path) -> Result<ExtractResult> {
    // UTF-16 input may need twice the space of the final UTF-8 text budget.
    let input_limit = MAX_TEXT_SIZE * 2;
    let mut bytes = Vec::new();
    File::open(path)
        .with_context(|| format!("cannot read {}", path.display()))?
        .take(input_limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    let input_truncated = bytes.len() > input_limit;
    bytes.truncate(input_limit);
    let mut result = decode(&bytes);
    result.truncated |= input_truncated;
    Ok(result)
}

fn decode(bytes: &[u8]) -> ExtractResult {
    let mut text = TextBuffer::default();
    if let Some((encoding, bom_len)) = encoding_rs::Encoding::for_bom(bytes) {
        let (decoded, _) = encoding.decode_without_bom_handling(&bytes[bom_len..]);
        text.push(&decoded);
    } else if let Some(encoding) = utf16_without_bom(bytes) {
        let (decoded, _) = encoding.decode_without_bom_handling(bytes);
        text.push(&decoded);
    } else if let Ok(utf8) = std::str::from_utf8(bytes) {
        text.push(utf8);
    } else {
        let sample = &bytes[..bytes.len().min(64 * 1024)];
        let mut detector = EncodingDetector::new();
        detector.feed(sample, sample.len() == bytes.len());
        let guessed = detector.guess(Some(b"cn"), true);
        let (decoded, had_errors) = guessed.decode_without_bom_handling(bytes);
        if !had_errors && guessed != UTF_8 {
            text.push(&decoded);
        } else {
            let (gb, errors) = GB18030.decode_without_bom_handling(bytes);
            if !errors {
                text.push(&gb);
            } else {
                text.push(&String::from_utf8_lossy(bytes));
            }
        }
    }
    text.finish(None)
}

fn utf16_without_bom(bytes: &[u8]) -> Option<&'static encoding_rs::Encoding> {
    let sample = &bytes[..bytes.len().min(4096)];
    if sample.len() < 4 || !sample.len().is_multiple_of(2) {
        return None;
    }
    let pairs = sample.len() / 2;
    let even_zeros = sample.iter().step_by(2).filter(|&&b| b == 0).count();
    let odd_zeros = sample
        .iter()
        .skip(1)
        .step_by(2)
        .filter(|&&b| b == 0)
        .count();
    if odd_zeros * 10 >= pairs * 3 && even_zeros * 10 < pairs {
        Some(UTF_16LE)
    } else if even_zeros * 10 >= pairs * 3 && odd_zeros * 10 < pairs {
        Some(UTF_16BE)
    } else if std::str::from_utf8(sample).is_err()
        || sample
            .iter()
            .any(|&byte| byte < 0x20 && !matches!(byte, b'\t' | b'\n' | b'\r'))
    {
        // Pure CJK UTF-16 can have no zero bytes; ordinary printable UTF-8 stays unambiguous.
        let cjk_score = |little_endian: bool| {
            sample
                .as_chunks::<2>()
                .0
                .iter()
                .filter(|pair| {
                    let word = if little_endian {
                        u16::from_le_bytes([pair[0], pair[1]])
                    } else {
                        u16::from_be_bytes([pair[0], pair[1]])
                    };
                    matches!(word, 0x3400..=0x4dbf | 0x4e00..=0x9fff)
                })
                .count()
        };
        let (le, be) = (cjk_score(true), cjk_score(false));
        if le >= 2 && le * 10 >= pairs * 8 && le > be {
            Some(UTF_16LE)
        } else if be >= 2 && be * 10 >= pairs * 8 && be > le {
            Some(UTF_16BE)
        } else {
            None
        }
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_and_gb18030_chinese() {
        let chinese = "\u{5408}\u{540c}\u{6761}\u{6b3e}\u{4e0e}\u{4e2d}\u{6587}\u{641c}\u{7d22}";
        assert_eq!(decode(chinese.as_bytes()).text, chinese);
        let (encoded, _, had_errors) = GB18030.encode(chinese);
        assert!(!had_errors);
        assert_eq!(decode(&encoded).text, chinese);
        let extended = "\u{4e2d}\u{6587}\u{5408}\u{540c}\u{20000}\u{6761}\u{6b3e}";
        let (encoded, _, had_errors) = GB18030.encode(extended);
        assert!(!had_errors);
        assert_eq!(decode(&encoded).text, extended);
    }

    #[test]
    fn utf16_bom_and_without_bom() {
        let input = "RustSearch \u{5408}\u{540c} 2026";
        let bytes: Vec<u8> = input.encode_utf16().flat_map(u16::to_le_bytes).collect();
        assert_eq!(decode(&bytes).text, input);
        let mut bom = vec![0xff, 0xfe];
        bom.extend(bytes);
        assert_eq!(decode(&bom).text, input);
        let mut be = vec![0xfe, 0xff];
        be.extend(input.encode_utf16().flat_map(u16::to_be_bytes));
        assert_eq!(decode(&be).text, input);
        let chinese = "\u{4e2d}\u{6587}\u{5168}\u{6587}\u{641c}\u{7d22}";
        let bytes: Vec<u8> = chinese.encode_utf16().flat_map(u16::to_le_bytes).collect();
        assert_eq!(decode(&bytes).text, chinese);
        assert_eq!(decode(b"abcdef").text, "abcdef");
    }

    #[test]
    fn plain_text_file_and_truncation() {
        let fixture = super::super::tests::Fixture::new("txt");
        std::fs::write(fixture.path(), "\u{4e2d}\u{6587} UTF-8").unwrap();
        assert_eq!(
            extract(fixture.path()).unwrap().text,
            "\u{4e2d}\u{6587} UTF-8"
        );
        assert!(decode(&vec![b'a'; MAX_TEXT_SIZE + 1]).truncated);
    }
}
