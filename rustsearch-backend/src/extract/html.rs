use super::{plain_text, ExtractResult, TextBuffer};
use anyhow::Result;
use scraper::{Html, Node, Selector};
use std::path::Path;

pub fn extract(path: &Path) -> Result<ExtractResult> {
    let source = plain_text::extract(path)?;
    let mut result = extract_html(&source.text);
    result.truncated |= source.truncated;
    Ok(result)
}

pub(super) fn extract_html(source: &str) -> ExtractResult {
    let document = Html::parse_document(source);
    let title = Selector::parse("title")
        .ok()
        .and_then(|selector| {
            document
                .select(&selector)
                .next()
                .map(|node| node.text().collect::<String>())
        })
        .map(|title| title.trim().chars().take(2048).collect::<String>())
        .filter(|title| !title.is_empty());
    let mut text = TextBuffer::default();
    for node in document.tree.root().descendants() {
        if node.ancestors().any(|parent| {
            matches!(parent.value(), Node::Element(element)
                if matches!(element.name(), "script" | "style" | "noscript" | "template" | "head"))
        }) {
            continue;
        }
        match node.value() {
            Node::Text(value) => {
                for word in value.text.split_whitespace() {
                    text.push(word);
                    text.push(" ");
                    if text.truncated {
                        break;
                    }
                }
            }
            Node::Element(element)
                if matches!(
                    element.name(),
                    "p" | "div"
                        | "br"
                        | "li"
                        | "tr"
                        | "h1"
                        | "h2"
                        | "h3"
                        | "h4"
                        | "h5"
                        | "h6"
                        | "section"
                        | "article"
                        | "pre"
                ) && !text.text.is_empty()
                    && !text.text.ends_with('\n') =>
            {
                text.push("\n");
            }
            _ => {}
        }
        if text.truncated {
            break;
        }
    }
    text.text.truncate(text.text.trim_end().len());
    text.finish(title)
}

#[cfg(test)]
mod tests {
    #[test]
    fn tolerant_html_entities_and_hidden_content() {
        let result = super::extract_html("<!doctype html><title>\u{5408}\u{540c}\u{7f51}\u{9875}</title><style>.x{color:red}</style><h1>\u{4e2d}\u{6587}&nbsp;\u{5408}\u{540c}</h1><script>if(a<b) secret();</script><p>\u{6761}\u{6b3e}&amp;\u{8bf4}\u{660e}<p>\u{7b2c}\u{4e8c}\u{6bb5}");
        assert_eq!(
            result.title.as_deref(),
            Some("\u{5408}\u{540c}\u{7f51}\u{9875}")
        );
        assert!(result.text.contains("\u{4e2d}\u{6587} \u{5408}\u{540c}"));
        assert!(result.text.contains("\u{6761}\u{6b3e}&\u{8bf4}\u{660e}"));
        assert!(!result.text.contains("secret"));
        assert!(!result.text.contains("color"));
    }
}
