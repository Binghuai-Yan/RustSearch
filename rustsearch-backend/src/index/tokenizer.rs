use anyhow::{Context, Result};
use jieba_rs::{Jieba, TokenizeMode};
use std::sync::{Arc, OnceLock};
use tantivy::{
    tokenizer::{LowerCaser, SimpleTokenizer, TextAnalyzer, Token, TokenStream, Tokenizer},
    Index,
};

static JIEBA: OnceLock<Arc<Jieba>> = OnceLock::new();
#[derive(Clone)]
pub struct MixedTokenizer {
    jieba: Option<Arc<Jieba>>,
}
impl MixedTokenizer {
    pub fn new(dictionary: &str) -> Result<Self> {
        if dictionary.trim().is_empty() {
            return Ok(Self { jieba: None });
        }
        let base = JIEBA.get_or_init(|| Arc::new(Jieba::new())).clone();
        let mut jieba = (*base).clone();
        jieba
            .load_dict(&mut std::io::Cursor::new(dictionary.as_bytes()))
            .context("Invalid user dictionary")?;
        Ok(Self {
            jieba: Some(Arc::new(jieba)),
        })
    }
}
pub struct MixedStream {
    tokens: std::vec::IntoIter<Token>,
    current: Token,
}
impl Tokenizer for MixedTokenizer {
    type TokenStream<'a> = MixedStream;
    fn token_stream<'a>(&'a mut self, text: &'a str) -> MixedStream {
        if self.jieba.is_none() {
            let mut tokenizer = tantivy_jieba::JiebaTokenizer {};
            let mut stream = tokenizer.token_stream(text);
            let mut tokens = vec![];
            while stream.advance() {
                let mut token = stream.token().clone();
                if !token.text.chars().any(char::is_alphanumeric) {
                    continue;
                }
                token.text = token.text.to_lowercase();
                tokens.push(token);
            }
            tokens.sort_by_key(|token| (token.offset_from, token.offset_to));
            return MixedStream {
                tokens: tokens.into_iter(),
                current: Token::default(),
            };
        }
        let mut offsets: Vec<usize> = text.char_indices().map(|(i, _)| i).collect();
        offsets.push(text.len());
        let mut tokens = self
            .jieba
            .as_ref()
            .unwrap()
            .tokenize(text, TokenizeMode::Search, true)
            .into_iter()
            .filter(|t| t.word.chars().any(char::is_alphanumeric))
            .map(|t| Token {
                offset_from: offsets[t.start],
                offset_to: offsets[t.end],
                position: t.start,
                text: t.word.to_lowercase(),
                position_length: t.end - t.start,
            })
            .collect::<Vec<_>>();
        tokens.sort_by_key(|token| (token.offset_from, token.offset_to));
        MixedStream {
            tokens: tokens.into_iter(),
            current: Token::default(),
        }
    }
}
impl TokenStream for MixedStream {
    fn advance(&mut self) -> bool {
        match self.tokens.next() {
            Some(token) => {
                self.current = token;
                true
            }
            None => false,
        }
    }
    fn token(&self) -> &Token {
        &self.current
    }
    fn token_mut(&mut self) -> &mut Token {
        &mut self.current
    }
}
pub fn register(index: &Index, dictionary: &str) -> Result<()> {
    index
        .tokenizers()
        .register("mixed", MixedTokenizer::new(dictionary)?);
    index.tokenizers().register(
        "simple_lower",
        TextAnalyzer::builder(SimpleTokenizer::default())
            .filter(LowerCaser)
            .build(),
    );
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn utf8_offsets_and_case() {
        let mut tokenizer = MixedTokenizer::new("").unwrap();
        let text = "合同 Rust SEARCH";
        let mut stream = tokenizer.token_stream(text);
        let mut found = vec![];
        while stream.advance() {
            let token = stream.token();
            assert_eq!(
                text[token.offset_from..token.offset_to].to_lowercase(),
                token.text
            );
            found.push(token.text.clone());
        }
        assert!(found.contains(&"合同".to_string()));
        assert!(found.contains(&"rust".to_string()));
    }
    #[test]
    fn overlapping_search_tokens_have_monotonic_offsets() {
        let mut tokenizer = MixedTokenizer::new("").unwrap();
        let mut stream = tokenizer.token_stream("甲方与乙方签订合同条款。北京大学");
        let mut previous = 0;
        while stream.advance() {
            let token = stream.token();
            assert!(token.offset_from >= previous);
            previous = token.offset_from;
        }
    }
}
