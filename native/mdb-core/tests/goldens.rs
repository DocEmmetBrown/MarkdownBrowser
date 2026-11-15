//! Replays the shared search conformance corpus in goldens/search.json.

use std::collections::BTreeMap;

use mdb_core::search::{SearchQuery, Searcher};

#[derive(Debug)]
enum Json {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

impl Json {
    fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(map) => map.get(key),
            _ => None,
        }
    }
    fn str(&self, key: &str) -> &str {
        match self.get(key) {
            Some(Json::String(s)) => s,
            other => panic!("{key}: expected string, got {other:?}"),
        }
    }
    fn bool(&self, key: &str) -> bool {
        matches!(self.get(key), Some(Json::Bool(true)))
    }
    fn num(&self, key: &str) -> u32 {
        match self.get(key) {
            Some(Json::Number(n)) => *n as u32,
            other => panic!("{key}: expected number, got {other:?}"),
        }
    }
    fn array(&self, key: &str) -> &[Json] {
        match self.get(key) {
            Some(Json::Array(items)) => items,
            other => panic!("{key}: expected array, got {other:?}"),
        }
    }
}

/// A minimal JSON reader for the goldens file (the test has no JSON dependency).
struct Reader<'a> {
    chars: std::iter::Peekable<std::str::Chars<'a>>,
}

impl Reader<'_> {
    fn skip_whitespace(&mut self) {
        while self.chars.peek().is_some_and(|c| c.is_whitespace()) {
            self.chars.next();
        }
    }

    fn expect(&mut self, expected: char) {
        self.skip_whitespace();
        assert_eq!(self.chars.next(), Some(expected));
    }

    fn value(&mut self) -> Json {
        self.skip_whitespace();
        match self.chars.peek().copied() {
            Some('{') => {
                self.chars.next();
                let mut map = BTreeMap::new();
                loop {
                    self.skip_whitespace();
                    if self.chars.peek() == Some(&'}') {
                        self.chars.next();
                        return Json::Object(map);
                    }
                    let Json::String(key) = self.value() else {
                        panic!("object key")
                    };
                    self.expect(':');
                    map.insert(key, self.value());
                    self.skip_whitespace();
                    if self.chars.peek() == Some(&',') {
                        self.chars.next();
                    }
                }
            }
            Some('[') => {
                self.chars.next();
                let mut items = Vec::new();
                loop {
                    self.skip_whitespace();
                    if self.chars.peek() == Some(&']') {
                        self.chars.next();
                        return Json::Array(items);
                    }
                    items.push(self.value());
                    self.skip_whitespace();
                    if self.chars.peek() == Some(&',') {
                        self.chars.next();
                    }
                }
            }
            Some('"') => {
                self.chars.next();
                let mut units: Vec<u16> = Vec::new();
                loop {
                    match self.chars.next().expect("unterminated string") {
                        '"' => {
                            return Json::String(String::from_utf16(&units).expect("valid UTF-16"));
                        }
                        '\\' => match self.chars.next().expect("escape") {
                            'n' => units.push(b'\n'.into()),
                            'r' => units.push(b'\r'.into()),
                            't' => units.push(b'\t'.into()),
                            'b' => units.push(8),
                            'f' => units.push(12),
                            'u' => {
                                let hex: String = (0..4)
                                    .map(|_| self.chars.next().expect("hex digit"))
                                    .collect();
                                units.push(u16::from_str_radix(&hex, 16).expect("hex escape"));
                            }
                            c => units.extend(c.encode_utf16(&mut [0; 2]).iter()),
                        },
                        c => units.extend(c.encode_utf16(&mut [0; 2]).iter()),
                    }
                }
            }
            Some('t') | Some('f') | Some('n') => {
                let word: String =
                    std::iter::from_fn(|| self.chars.next_if(|c| c.is_ascii_alphabetic()))
                        .collect();
                match word.as_str() {
                    "true" => Json::Bool(true),
                    "false" => Json::Bool(false),
                    "null" => Json::Null,
                    _ => panic!("unexpected {word}"),
                }
            }
            _ => {
                let number: String = std::iter::from_fn(|| {
                    self.chars
                        .next_if(|c| matches!(c, '-' | '+' | '.' | 'e' | 'E' | '0'..='9'))
                })
                .collect();
                Json::Number(number.parse().expect("number"))
            }
        }
    }
}

#[test]
fn search_matches_the_conformance_corpus() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../goldens/search.json");
    let text = std::fs::read_to_string(path).expect("goldens/search.json");
    let goldens = Reader {
        chars: text.chars().peekable(),
    }
    .value();
    let docs = goldens.array("docs");
    let cases = goldens.array("cases");
    assert!(cases.len() > 1000);

    let mut failures = Vec::new();
    let (mut matches, mut replacements) = (0, 0);
    for golden in cases {
        let doc = &docs[golden.num("doc") as usize];
        let query = SearchQuery {
            search: golden.str("search").into(),
            case_sensitive: golden.bool("caseSensitive"),
            regexp: golden.bool("regexp"),
        };
        let label = format!(
            "{} {}{:?}{}",
            doc.str("name"),
            if query.regexp { "/" } else { "\"" },
            query.search,
            if query.case_sensitive {
                ""
            } else {
                " (ignoring case)"
            }
        );
        let searcher = Searcher::new(query);
        let valid = searcher.validation_error().is_none();
        if valid != golden.bool("valid") {
            failures.push(format!("{label}: valid should be {}", golden.bool("valid")));
        }
        let limit = if doc.str("name") == "long" {
            300
        } else {
            10_000
        };
        let found: Vec<u32> = searcher
            .find(
                doc.str("text").into(),
                doc.str("lineSeparator").into(),
                limit,
            )
            .iter()
            .flat_map(|m| [m.line, m.column, m.length])
            .collect();
        let expected: Vec<u32> = golden
            .array("find")
            .iter()
            .map(|n| match n {
                Json::Number(n) => *n as u32,
                _ => panic!("find"),
            })
            .collect();
        matches += expected.len() / 3;
        if found != expected {
            failures.push(format!("{label}: found {found:?}, expected {expected:?}"));
        }
        for replacement in golden.array("replacements") {
            let template = replacement.str("template");
            replacements += usize::from(replacement.num("count") > 0);
            let result = searcher.replace(
                doc.str("text").into(),
                doc.str("lineSeparator").into(),
                template.into(),
            );
            let expected_text = match replacement.get("text") {
                Some(Json::String(text)) => text.as_str(),
                _ => doc.str("text"),
            };
            if result.count != replacement.num("count") || result.text != expected_text {
                failures.push(format!(
                    "{label} -> {template:?}: replaced {} {:?}, expected {} {:?}",
                    result.count,
                    result.text,
                    replacement.num("count"),
                    expected_text
                ));
            }
        }
    }
    assert!(
        matches > 10_000 && replacements > 800,
        "compared {matches} matches and {replacements} replacements"
    );
    assert!(
        failures.is_empty(),
        "{} mismatches:\n{}",
        failures.len(),
        failures
            .iter()
            .take(40)
            .map(|f| f.chars().take(400).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    );
}

#[test]
fn replaces_only_the_selected_match_with_full_document_regex_context() {
    let searcher = Searcher::new(SearchQuery {
        search: r"(?<=😀 )(foo)(?=!)".into(),
        case_sensitive: true,
        regexp: true,
    });
    assert_eq!(
        searcher.replace_match("😀 foo! foo!".into(), "\n".into(), 1, 3, "$1x".into()),
        Some("😀 foox! foo!".into())
    );

    let searcher = Searcher::new(SearchQuery {
        search: "foo".into(),
        case_sensitive: true,
        regexp: false,
    });
    assert_eq!(
        searcher.replace_match(
            "first\r\nfoo\r\nfoo\r\n".into(),
            "\r\n".into(),
            2,
            0,
            "bar".into()
        ),
        Some("first\r\nbar\r\nfoo\r\n".into())
    );
    assert_eq!(
        searcher.replace_match("first\r\nfoo".into(), "\r\n".into(), 2, 1, "bar".into()),
        None
    );
}
