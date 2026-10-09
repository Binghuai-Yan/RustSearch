use crate::{
    index::Engine,
    ipc::protocol::{SearchHit, SearchParams, SearchResult},
    path_utils,
};
use anyhow::{bail, Context, Result};
use std::{ops::Bound, path::Path, sync::atomic::Ordering, time::Instant};
use tantivy::{
    collector::{Count, TopDocs},
    query::{
        AllQuery, BooleanQuery, BoostQuery, EmptyQuery, Occur, PhraseQuery, Query, RangeQuery,
        RegexQuery, TermQuery,
    },
    schema::{IndexRecordOption, Value},
    tokenizer::TokenStream,
    DocAddress, Order, SnippetGenerator, TantivyDocument, Term,
};

struct Clause {
    sign: Option<char>,
    text: String,
    phrase: bool,
}
#[derive(Debug)]
pub struct QuerySyntaxError(String);
impl std::fmt::Display for QuerySyntaxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for QuerySyntaxError {}
fn lex(input: &str) -> Result<Vec<Clause>> {
    let mut chars = input.chars().peekable();
    let mut result = vec![];
    while chars.peek().is_some() {
        while chars.peek().is_some_and(|c| c.is_whitespace()) {
            chars.next();
        }
        if chars.peek().is_none() {
            break;
        }
        let sign = if chars.peek().is_some_and(|c| *c == '+' || *c == '-') {
            chars.next()
        } else {
            None
        };
        let mut text = String::new();
        let mut quoted = false;
        let mut phrase = false;
        for c in chars.by_ref() {
            if c == '"' {
                quoted = !quoted;
                phrase = true;
                continue;
            }
            if c.is_whitespace() && !quoted {
                break;
            }
            text.push(c);
        }
        if quoted {
            bail!("Unclosed quote");
        }
        if text.is_empty() {
            bail!("Empty search clause");
        }
        result.push(Clause { sign, text, phrase });
    }
    Ok(result)
}
fn numeric_range(engine: &Engine, field: &str, expression: &str) -> Result<Box<dyn Query>> {
    let (op, value) = if let Some(v) = expression.strip_prefix(">=") {
        (">=", v)
    } else if let Some(v) = expression.strip_prefix("<=") {
        ("<=", v)
    } else if let Some(v) = expression.strip_prefix('>') {
        (">", v)
    } else if let Some(v) = expression.strip_prefix('<') {
        ("<", v)
    } else {
        ("=", expression)
    };
    let n = if field == "size" {
        parse_size(value)?
    } else {
        parse_date(value)?
    };
    let (low, high) = match op {
        ">" => (Bound::Excluded(n), Bound::Unbounded),
        ">=" => (Bound::Included(n), Bound::Unbounded),
        "<" => (Bound::Unbounded, Bound::Excluded(n)),
        "<=" => (Bound::Unbounded, Bound::Included(n)),
        _ => (Bound::Included(n), Bound::Included(n)),
    };
    let _ = engine;
    Ok(Box::new(RangeQuery::new_u64_bounds(
        if field == "date" { "mtime" } else { "size" }.to_string(),
        low,
        high,
    )))
}
fn parse_size(input: &str) -> Result<u64> {
    let lower = input.to_lowercase();
    let (number, mult) = [
        ("gb", 1024f64.powi(3)),
        ("mb", 1024f64.powi(2)),
        ("kb", 1024.0),
        ("b", 1.0),
    ]
    .into_iter()
    .find_map(|(suffix, m)| lower.strip_suffix(suffix).map(|v| (v, m)))
    .unwrap_or((&lower, 1.0));
    let n = number.parse::<f64>().context("Invalid size filter")? * mult;
    anyhow::ensure!(
        n.is_finite() && n >= 0.0 && n < u64::MAX as f64,
        "Invalid size filter"
    );
    Ok(n as u64)
}
fn parse_date(input: &str) -> Result<u64> {
    use chrono::{Local, NaiveDate, TimeZone};
    let date = NaiveDate::parse_from_str(input, "%Y-%m-%d").context("Date must be YYYY-MM-DD")?;
    let seconds = Local
        .from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap())
        .earliest()
        .context("Invalid local date")?
        .timestamp();
    Ok(seconds.max(0) as u64)
}
fn extension_query(engine: &Engine, extensions: &[String]) -> Result<Box<dyn Query>> {
    let mut terms = vec![];
    for extension in extensions {
        let ext = extension.trim().trim_start_matches('.').to_lowercase();
        anyhow::ensure!(
            !ext.is_empty() && ext.chars().all(char::is_alphanumeric),
            "Invalid extension"
        );
        terms.push((
            Occur::Should,
            Box::new(TermQuery::new(
                Term::from_field_text(engine.fields.ext, &ext),
                IndexRecordOption::Basic,
            )) as Box<dyn Query>,
        ));
    }
    Ok(Box::new(BooleanQuery::new(terms)))
}
fn text_query(engine: &Engine, clause: &Clause) -> Result<Box<dyn Query>> {
    let mut analyzer = engine
        .index
        .tokenizers()
        .get("mixed")
        .context("Missing mixed tokenizer")?;
    let mut stream = analyzer.token_stream(&clause.text);
    let mut tokens = vec![];
    while stream.advance() {
        tokens.push((
            stream.token().position,
            stream.token().position_length,
            stream.token().text.clone(),
        ));
    }
    if tokens.is_empty() {
        return Ok(Box::new(EmptyQuery));
    }
    if clause.phrase {
        tokens.sort_by_key(|(position, length, _)| (*position, std::cmp::Reverse(*length)));
        let mut end = 0;
        tokens.retain(|(position, length, _)| {
            if *position < end {
                false
            } else {
                end = position + length;
                true
            }
        });
    }
    let mut queries = vec![];
    for (field, boost) in [
        (engine.fields.filename, 3.0),
        (engine.fields.content, 1.0),
        (engine.fields.title, 2.0),
    ] {
        let terms: Vec<_> = tokens
            .iter()
            .map(|(position, _, t)| (*position, Term::from_field_text(field, t)))
            .collect();
        let query: Box<dyn Query> = if clause.phrase && terms.len() > 1 {
            Box::new(PhraseQuery::new_with_offset(terms))
        } else {
            Box::new(BooleanQuery::new(
                terms
                    .into_iter()
                    .map(|(_, t)| {
                        (
                            Occur::Should,
                            Box::new(TermQuery::new(t, IndexRecordOption::WithFreqsAndPositions))
                                as Box<dyn Query>,
                        )
                    })
                    .collect(),
            ))
        };
        queries.push((
            Occur::Should,
            Box::new(BoostQuery::new(query, boost)) as Box<dyn Query>,
        ));
    }
    Ok(Box::new(BooleanQuery::new(queries)))
}
fn build_query(engine: &Engine, params: &SearchParams) -> Result<Box<dyn Query>> {
    let mut clauses = vec![];
    let mut positive = false;
    let mut required_text = false;
    for clause in lex(&params.query)? {
        let mut filter = false;
        let query: Box<dyn Query> = if let Some((field, value)) = clause.text.split_once(':') {
            match field.to_lowercase().as_str() {
                "ext" => {
                    filter = true;
                    extension_query(
                        engine,
                        &value.split(',').map(str::to_string).collect::<Vec<_>>(),
                    )?
                }
                "size" | "date" => {
                    filter = true;
                    numeric_range(engine, &field.to_lowercase(), value)?
                }
                "path" => {
                    filter = true;
                    let raw_prefix = value.trim_end_matches('*');
                    // Match the canonical form stored by the index (including expansion of
                    // Windows 8.3 names), while retaining a useful fallback for paths that
                    // do not exist yet.
                    let prefix = path_utils::canonical(Path::new(raw_prefix))
                        .map(|path| path_utils::key(&path))
                        .unwrap_or_else(|_| path_utils::key(Path::new(raw_prefix)));
                    let pattern = format!("{}.*", regex::escape(&prefix));
                    Box::new(RegexQuery::from_pattern(&pattern, engine.fields.path)?)
                }
                _ => bail!("Unknown query field: {field}"),
            }
        } else {
            text_query(engine, &clause)?
        };
        let occur = match clause.sign {
            Some('-') => Occur::MustNot,
            Some('+') => Occur::Must,
            _ if filter => Occur::Must,
            _ => Occur::Should,
        };
        if occur == Occur::Must && !filter {
            required_text = true;
        }
        if occur != Occur::MustNot {
            positive = true;
        }
        clauses.push((occur, query));
    }
    if !params.ext.is_empty() {
        clauses.push((Occur::Must, extension_query(engine, &params.ext)?));
        positive = true;
    }
    // Optional keywords still constrain a query when mandatory filters are present.
    let mut optional = vec![];
    let mut required = vec![];
    for (occur, query) in clauses {
        if occur == Occur::Should {
            optional.push((occur, query));
        } else {
            required.push((occur, query));
        }
    }
    if !optional.is_empty() {
        required.push((
            if required_text {
                Occur::Should
            } else {
                Occur::Must
            },
            Box::new(BooleanQuery::new(optional)),
        ));
    }
    if !positive {
        required.push((Occur::Must, Box::new(AllQuery)));
    }
    Ok(Box::new(BooleanQuery::new(required)))
}
pub fn search(engine: &Engine, mut params: SearchParams) -> Result<SearchResult> {
    let started = Instant::now();
    validate_search(&params)?;
    let offset = params.page * params.page_size;
    params.ext.sort();
    let cache_key = serde_json::to_string(&params)?;
    let generation = engine.generation.load(Ordering::SeqCst);
    let cached = engine
        .cache
        .lock()
        .unwrap()
        .iter()
        .find(|(key, g, _)| key == &cache_key && *g == generation)
        .map(|(_, _, r)| r.clone());
    if let Some(mut result) = cached {
        engine.meta.lock().unwrap().record_query(&params.query)?;
        result.elapsed_ms = started.elapsed().as_millis();
        return Ok(result);
    }
    let query = build_query(engine, &params).map_err(|e| QuerySyntaxError(e.to_string()))?;
    engine.meta.lock().unwrap().record_query(&params.query)?;
    search_query(
        engine, params, started, offset, cache_key, generation, query,
    )
}
pub fn validate_search(params: &SearchParams) -> Result<()> {
    anyhow::ensure!(params.query.len() <= 4096, "Query exceeds 4096 bytes");
    anyhow::ensure!(
        (1..=100).contains(&params.page_size),
        "page_size must be between 1 and 100"
    );
    anyhow::ensure!(
        [
            "relevance",
            "mtime",
            "mtime_desc",
            "size",
            "size_desc",
            "size_asc"
        ]
        .contains(&params.sort.as_str()),
        "Unknown sort order"
    );
    let offset = params
        .page
        .checked_mul(params.page_size)
        .context("Page is too large")?;
    anyhow::ensure!(offset <= 1_000_000, "Page exceeds supported range");
    Ok(())
}
fn search_query(
    engine: &Engine,
    params: SearchParams,
    started: Instant,
    offset: usize,
    cache_key: String,
    generation: u64,
    query: Box<dyn Query>,
) -> Result<SearchResult> {
    let searcher = engine.reader.searcher();
    let (total_hits, documents): (usize, Vec<(f32, DocAddress)>) = if params.sort == "relevance" {
        searcher.search(
            &query,
            &(
                Count,
                TopDocs::with_limit(params.page_size).and_offset(offset),
            ),
        )?
    } else {
        let field = if params.sort.starts_with("mtime") {
            "mtime"
        } else {
            "size"
        };
        let order = if params.sort == "size_asc" {
            Order::Asc
        } else {
            Order::Desc
        };
        let (count, docs) = searcher.search(
            &query,
            &(
                Count,
                TopDocs::with_limit(params.page_size)
                    .and_offset(offset)
                    .order_by_u64_field(field, order),
            ),
        )?;
        (
            count,
            docs.into_iter().map(|(_, addr)| (0.0, addr)).collect(),
        )
    };
    let mut content_snippet =
        SnippetGenerator::create(&searcher, query.as_ref(), engine.fields.content)?;
    content_snippet.set_max_num_chars(180);
    let mut filename_snippet =
        SnippetGenerator::create(&searcher, query.as_ref(), engine.fields.filename)?;
    filename_snippet.set_max_num_chars(512);
    let mut highlight_terms = std::collections::BTreeSet::new();
    query.query_terms(&mut |term, _| {
        if term.field() == engine.fields.content {
            if let Some(text) = term.value().as_str() {
                highlight_terms.insert(text.to_ascii_lowercase());
            }
        }
    });
    let mut hits = Vec::with_capacity(documents.len());
    for (score, address) in documents {
        let doc: TantivyDocument = searcher.doc(address)?;
        let text = |f| {
            doc.get_first(f)
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_owned()
        };
        let path = text(engine.fields.display_path);
        let filename = text(engine.fields.filename);
        let (content, ocr_pages) = {
            let meta = engine.meta.lock().unwrap();
            let key = text(engine.fields.path);
            (meta.content(&key)?, meta.ocr_pages(&key)?)
        };
        let ocr_page = ocr_pages.into_iter().find_map(|(page, offset, length)| {
            content
                .get(offset..offset.checked_add(length)?)
                .filter(|value| {
                    let normalized = value.to_lowercase();
                    highlight_terms.iter().any(|term| normalized.contains(term))
                })
                .map(|_| page)
        });
        let snippets = snippet_windows(&content, &highlight_terms)
            .into_iter()
            .map(|window| {
                let html = content_snippet.snippet(window).to_html();
                if html.is_empty() {
                    escape_html(&window.chars().take(180).collect::<String>())
                } else {
                    html
                }
            })
            .collect();
        let filename_hl = filename_snippet.snippet(&filename).to_html();
        let filename_hl = if filename_hl.is_empty() {
            escape_html(&filename)
        } else {
            filename_hl
        };
        hits.push(SearchHit {
            path,
            filename_hl,
            filename,
            ext: text(engine.fields.ext),
            size: doc
                .get_first(engine.fields.size)
                .and_then(|v| v.as_u64())
                .unwrap_or(0),
            mtime: doc
                .get_first(engine.fields.mtime)
                .and_then(|v| v.as_u64())
                .unwrap_or(0),
            score,
            snippets,
            ocr_page,
        });
    }
    let result = SearchResult {
        total_hits,
        elapsed_ms: started.elapsed().as_millis(),
        hits,
        page: params.page,
        page_size: params.page_size,
    };
    let mut cache = engine.cache.lock().unwrap();
    if cache.len() >= 32 {
        cache.pop_front();
    }
    cache.push_back((cache_key, generation, result.clone()));
    Ok(result)
}
fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
fn snippet_windows<'a>(
    content: &'a str,
    terms: &std::collections::BTreeSet<String>,
) -> Vec<&'a str> {
    let lowercase = content.to_ascii_lowercase();
    let mut positions: Vec<_> = terms
        .iter()
        .filter_map(|term| lowercase.find(term))
        .collect();
    positions.sort_unstable();
    positions.dedup();
    if positions.is_empty() {
        positions.push(0);
    }
    let mut ranges = vec![];
    for position in positions {
        let mut start = position.saturating_sub(240);
        let mut end = (position + 720).min(content.len());
        while !content.is_char_boundary(start) {
            start += 1;
        }
        while !content.is_char_boundary(end) {
            end -= 1;
        }
        if ranges
            .last()
            .is_some_and(|(_, previous_end)| start < *previous_end)
        {
            continue;
        }
        ranges.push((start, end));
        if ranges.len() == 3 {
            break;
        }
    }
    ranges
        .into_iter()
        .map(|(start, end)| &content[start..end])
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parsing() {
        let q = lex("+合同 -过期 \"精确 短语\" path:\"C:\\my docs\\*\" ext:pdf,txt").unwrap();
        assert_eq!(q.len(), 5);
        assert_eq!(q[0].sign, Some('+'));
        assert!(q[2].phrase);
        assert_eq!(q[3].text, "path:C:\\my docs\\*");
        assert!(lex("\"unclosed").is_err());
        assert_eq!(parse_size("1.5mb").unwrap(), 1572864);
        assert!(parse_size("NaN").is_err());
        assert!(parse_date("2026-02-30").is_err());
    }
}
