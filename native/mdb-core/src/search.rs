//! Shared native find and replace with ECMAScript regular expressions.
//! Positions are UTF-16 offsets with the file's line separator counting as one `\n`.
//! Search behavior retains CodeMirror cursor compatibility, checked by `goldens/search.json`.

use std::sync::Arc;

use regress::{Flags, Regex};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchQuery {
    pub search: String,
    pub case_sensitive: bool,
    pub regexp: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SearchMatch {
    /// 1-based line number.
    pub line: u32,
    /// 0-based UTF-16 units from the start of the line.
    pub column: u32,
    /// Length in UTF-16 units; a match spanning lines counts each line break as one.
    pub length: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Replacement {
    pub text: String,
    pub count: u32,
}

/// A compiled query, reused across documents.
#[derive(uniffi::Object)]
pub struct Searcher {
    regexp: bool,
    matcher: Matcher,
}

enum Matcher {
    Nothing,
    Invalid(String),
    Literal(Vec<u16>, bool),
    Regex { regex: Regex, multiline: bool },
}

#[uniffi::export]
impl Searcher {
    #[uniffi::constructor]
    pub fn new(query: SearchQuery) -> Arc<Self> {
        Arc::new(Self {
            regexp: query.regexp,
            matcher: Matcher::new(&query),
        })
    }

    /// The error for an invalid regular expression, or nil.
    pub fn validation_error(&self) -> Option<String> {
        match &self.matcher {
            Matcher::Invalid(message) => Some(message.clone()),
            _ => None,
        }
    }

    /// At most `limit` matches in `text` split on `line_separator`, as the editor splits it.
    pub fn find(&self, text: String, line_separator: String, limit: u32) -> Vec<SearchMatch> {
        let mut result = Vec::new();
        if limit == 0 {
            return result;
        }
        let doc = Doc::new(&text, separator_or_newline(&line_separator));
        self.matcher.each(&doc, |found| {
            let line = doc.line_at(found.from);
            result.push(SearchMatch {
                line: (line + 1) as u32,
                column: (found.from - doc.line_starts[line]) as u32,
                length: (found.to - found.from) as u32,
            });
            result.len() < limit as usize
        });
        result
    }

    /// Replaces every match. In regex mode `template` expands `$&`, `$1`… and `$$`, and `\n`, `\r`, `\t`, `\\`;
    /// line breaks in the result become `line_separator`.
    pub fn replace(&self, text: String, line_separator: String, template: String) -> Replacement {
        let line_separator = separator_or_newline(&line_separator);
        let doc = Doc::new(&text, line_separator);
        let original: Vec<u16> = text.encode_utf16().collect();
        let separator_extra = line_separator.encode_utf16().count().max(1) - 1;
        let original_offset = |pos: usize| pos + doc.line_at(pos) * separator_extra;
        let mut output = Vec::with_capacity(original.len());
        let mut cursor = 0;
        let mut count = 0;
        self.matcher.each(&doc, |found| {
            let insert = if self.regexp {
                expand(&template, &found, &doc.units)
            } else {
                template.clone()
            };
            let insert = if line_separator == "\n" {
                insert
            } else {
                insert.replace('\n', line_separator)
            };
            let (from, to) = (original_offset(found.from), original_offset(found.to));
            output.extend_from_slice(&original[cursor..from]);
            output.extend(insert.encode_utf16());
            cursor = to;
            count += 1;
            true
        });
        if count == 0 {
            return Replacement { text, count: 0 };
        }
        output.extend_from_slice(&original[cursor..]);
        Replacement {
            text: String::from_utf16_lossy(&output),
            count,
        }
    }

    /// Replaces the match at the given 1-based line and UTF-16 column, preserving regex context.
    pub fn replace_match(
        &self,
        text: String,
        line_separator: String,
        line: u32,
        column: u32,
        template: String,
    ) -> Option<String> {
        let line_separator = separator_or_newline(&line_separator);
        let doc = Doc::new(&text, line_separator);
        let line_index = line.checked_sub(1)? as usize;
        let from = *doc.line_starts.get(line_index)? + column as usize;
        if from > doc.line_end(line_index) {
            return None;
        }

        let mut selected = None;
        self.matcher.each(&doc, |found| {
            if found.from == from {
                selected = Some(found);
                false
            } else {
                true
            }
        });
        let found = selected?;

        let original: Vec<u16> = text.encode_utf16().collect();
        let separator_extra = line_separator.encode_utf16().count().max(1) - 1;
        let original_offset = |position: usize| position + doc.line_at(position) * separator_extra;
        let start = original_offset(found.from);
        let end = original_offset(found.to);
        let replacement = if self.regexp {
            expand(&template, &found, &doc.units)
        } else {
            template
        };
        let replacement = if line_separator == "\n" {
            replacement
        } else {
            replacement.replace('\n', line_separator)
        };

        let mut output = Vec::with_capacity(original.len() + replacement.len());
        output.extend_from_slice(&original[..start]);
        output.extend(replacement.encode_utf16());
        output.extend_from_slice(&original[end..]);
        Some(String::from_utf16_lossy(&output))
    }
}

/// An empty separator means the editor's default, `\n`.
fn separator_or_newline(line_separator: &str) -> &str {
    if line_separator.is_empty() {
        "\n"
    } else {
        line_separator
    }
}

/// Search text normalized to UTF-16 units with each document line separator replaced by `\n`.
struct Doc {
    units: Vec<u16>,
    line_starts: Vec<usize>,
}

impl Doc {
    fn new(text: &str, line_separator: &str) -> Self {
        let mut units = Vec::with_capacity(text.len());
        let mut line_starts = vec![0];
        for (index, line) in text.split(line_separator).enumerate() {
            if index > 0 {
                units.push(NEWLINE);
                line_starts.push(units.len());
            }
            units.extend(line.encode_utf16());
        }
        Self { units, line_starts }
    }

    fn line_at(&self, pos: usize) -> usize {
        self.line_starts.partition_point(|&start| start <= pos) - 1
    }

    fn line_end(&self, line: usize) -> usize {
        self.line_starts
            .get(line + 1)
            .map_or(self.units.len(), |next| next - 1)
    }

    /// Moves past the low half of a surrogate pair.
    fn char_end(&self, mut pos: usize) -> usize {
        while pos < self.units.len() && (0xDC00..0xE000).contains(&self.units[pos]) {
            pos += 1;
        }
        pos
    }
}

const NEWLINE: u16 = b'\n' as u16;
/// Initial multiline search window, doubled as more context is needed.
const CHUNK: usize = 5000;

struct Found {
    from: usize,
    to: usize,
    /// Absolute ranges of the capture groups, for `$1`….
    captures: Vec<Option<(usize, usize)>>,
}

impl Matcher {
    fn new(query: &SearchQuery) -> Self {
        if query.search.is_empty() {
            return Matcher::Nothing;
        }
        if !query.regexp {
            return Matcher::Literal(
                normalize(&query.search, query.case_sensitive),
                query.case_sensitive,
            );
        }
        // Validate with the base flags before applying case-insensitive matching.
        let flags = |icase| Flags {
            multiline: true,
            unicode: true,
            icase,
            ..Flags::default()
        };
        if let Err(error) = Regex::with_flags(&query.search, flags(false)) {
            return Matcher::Invalid(format!(
                "Invalid regular expression: /{}/gmu: {}",
                query.search, error
            ));
        }
        match Regex::with_flags(&query.search, flags(!query.case_sensitive)) {
            Ok(regex) => Matcher::Regex {
                regex,
                multiline: is_multiline(&query.search),
            },
            Err(error) => Matcher::Invalid(format!(
                "Invalid regular expression: /{}/gmui: {}",
                query.search, error
            )),
        }
    }

    /// Calls `visit` with each non-empty match until it returns false.
    fn each(&self, doc: &Doc, mut visit: impl FnMut(Found) -> bool) {
        match self {
            Matcher::Nothing | Matcher::Invalid(_) => {}
            Matcher::Literal(query, case_sensitive) => {
                literal_matches(doc, query, *case_sensitive, visit)
            }
            Matcher::Regex {
                regex,
                multiline: false,
            } => {
                for line in 0..doc.line_starts.len() {
                    let start = doc.line_starts[line];
                    let text = &doc.units[start..doc.line_end(line)];
                    let mut offset = 0;
                    while offset <= text.len() {
                        let Some(found) = regex.find_from_utf16(text, offset).next() else {
                            break;
                        };
                        let (from, to) = (found.range.start, found.range.end);
                        if from < to {
                            let captures = shift(&found.captures, start);
                            if !visit(Found {
                                from: start + from,
                                to: start + to,
                                captures,
                            }) {
                                return;
                            }
                            offset = to;
                        } else {
                            offset = doc.char_end(start + to + 1) - start;
                        }
                    }
                }
            }
            Matcher::Regex {
                regex,
                multiline: true,
            } => {
                let length = doc.units.len();
                let chunk_end = |pos: usize| {
                    if pos >= length {
                        length
                    } else {
                        doc.line_end(doc.line_at(pos))
                    }
                };
                let mut flat_end = chunk_end(CHUNK);
                let mut position = 0;
                loop {
                    let flat = &doc.units[..flat_end];
                    let exec = |at: usize| {
                        if at <= flat.len() {
                            regex.find_from_utf16(flat, at).next()
                        } else {
                            None
                        }
                    };
                    let mut found = exec(position);
                    // Skip empty matches directly after the last match.
                    if let Some(empty) = &found
                        && empty.range.is_empty()
                        && empty.range.start == position
                    {
                        found = exec(position + 1);
                    }
                    if let Some(found) = found {
                        let (from, to) = (found.range.start, found.range.end);
                        // A match ending near the end of an incomplete chunk is retried on a longer one.
                        if flat_end >= length || to + 10 <= flat_end {
                            if from < to
                                && !visit(Found {
                                    from,
                                    to,
                                    captures: shift(&found.captures, 0),
                                })
                            {
                                return;
                            }
                            position = doc.char_end(to + usize::from(from == to));
                            continue;
                        }
                    }
                    if flat_end == length {
                        return;
                    }
                    flat_end = chunk_end(flat_end * 2);
                }
            }
        }
    }
}

/// Identifies patterns that need multiline search windows rather than per-line matching.
fn is_multiline(pattern: &str) -> bool {
    let chars: Vec<char> = pattern.chars().collect();
    chars
        .windows(2)
        .any(|pair| matches!(pair, ['\\', 's' | 'W' | 'D' | 'n' | 'r'] | ['[', '^']))
        || chars.iter().any(|&c| c == '\n' || c == '\r')
}

fn shift(captures: &[Option<regress::Range>], by: usize) -> Vec<Option<(usize, usize)>> {
    captures
        .iter()
        .map(|range| {
            range
                .as_ref()
                .map(|range| (range.start + by, range.end + by))
        })
        .collect()
}

/// Literal-search normalization: NFKD, then lowercase when ignoring case.
fn normalize(text: &str, case_sensitive: bool) -> Vec<u16> {
    let decomposed: String = text.nfkd().collect();
    if case_sensitive {
        decomposed.encode_utf16().collect()
    } else {
        decomposed.to_lowercase().encode_utf16().collect()
    }
}

fn normalize_char(c: char, case_sensitive: bool, into: &mut Vec<u16>) {
    into.clear();
    if c.is_ascii() {
        into.push(if case_sensitive {
            c as u16
        } else {
            c.to_ascii_lowercase() as u16
        });
    } else {
        into.extend(normalize(c.encode_utf8(&mut [0; 4]), case_sensitive));
    }
}

/// Compares normalized UTF-16 units while mapping matches back to original document positions.
fn literal_matches(
    doc: &Doc,
    query: &[u16],
    case_sensitive: bool,
    mut visit: impl FnMut(Found) -> bool,
) {
    struct Partial {
        from: usize,
        index: usize,
    }
    let Some(&first) = query.first() else { return };
    let mut partials: Vec<Partial> = Vec::new();
    let mut normalized = Vec::new();
    let mut original = [0u16; 2];
    let units = &doc.units;
    let mut index = 0;
    while index < units.len() {
        let start = index;
        let (c, size) = match char::decode_utf16(units[index..].iter().copied()).next() {
            Some(Ok(c)) => (c, c.len_utf16()),
            _ => (char::REPLACEMENT_CHARACTER, 1),
        };
        index += size;
        let source: &[u16] = c.encode_utf16(&mut original);
        normalize_char(c, case_sensitive, &mut normalized);
        let mut pos = start;
        let mut precise = true;
        for (i, &code) in normalized.iter().enumerate() {
            let mut found = None;
            partials.retain_mut(|partial| {
                if query[partial.index] != code {
                    return false;
                }
                if partial.index == query.len() - 1 {
                    found = Some(partial.from);
                    return false;
                }
                partial.index += 1;
                true
            });
            if first == code {
                if query.len() == 1 {
                    found = Some(pos);
                } else {
                    partials.push(Partial {
                        from: pos,
                        index: 1,
                    });
                }
            }
            if let Some(from) = found {
                partials.clear();
                if !visit(Found {
                    from,
                    to: index,
                    captures: Vec::new(),
                }) {
                    return;
                }
                break;
            }
            if precise && i < source.len() && source[i] == code {
                pos += 1;
            } else {
                precise = false;
            }
        }
    }
}

/// Expands capture references and escaped characters in regex replacement templates.
fn expand(template: &str, found: &Found, units: &[u16]) -> String {
    let group = |index: usize| -> Option<String> {
        let range = if index == 0 {
            Some((found.from, found.to))
        } else {
            *found.captures.get(index - 1)?
        };
        Some(
            range
                .map(|(from, to)| String::from_utf16_lossy(&units[from..to]))
                .unwrap_or_default(),
        )
    };
    let groups = found.captures.len() + 1;

    let mut unquoted = String::with_capacity(template.len());
    let mut chars = template.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            let mapped = match chars.peek() {
                Some('n') => Some('\n'),
                Some('r') => Some('\r'),
                Some('t') => Some('\t'),
                Some('\\') => Some('\\'),
                _ => None,
            };
            if let Some(mapped) = mapped {
                unquoted.push(mapped);
                chars.next();
                continue;
            }
        }
        unquoted.push(c);
    }

    let chars: Vec<char> = unquoted.chars().collect();
    let mut output = String::with_capacity(unquoted.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '$' && i + 1 < chars.len() {
            match chars[i + 1] {
                '$' => {
                    output.push('$');
                    i += 2;
                    continue;
                }
                '&' => {
                    output.push_str(&group(0).unwrap_or_default());
                    i += 2;
                    continue;
                }
                '0'..='9' => {
                    let digits: String = chars[i + 1..]
                        .iter()
                        .take_while(|c| c.is_ascii_digit())
                        .collect();
                    i += 1 + digits.len();
                    let reference = (1..=digits.len()).rev().find_map(|length| {
                        let index: usize = digits[..length].parse().ok()?;
                        (index > 0 && index < groups)
                            .then(|| (group(index).unwrap_or_default(), length))
                    });
                    match reference {
                        Some((text, length)) => {
                            output.push_str(&text);
                            output.push_str(&digits[length..]);
                        }
                        None => {
                            output.push('$');
                            output.push_str(&digits);
                        }
                    }
                    continue;
                }
                _ => {}
            }
        }
        output.push(chars[i]);
        i += 1;
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query(search: &str, case_sensitive: bool, regexp: bool) -> SearchQuery {
        SearchQuery {
            search: search.into(),
            case_sensitive,
            regexp,
        }
    }

    fn find(text: &str, separator: &str, q: SearchQuery, limit: u32) -> Vec<u32> {
        Searcher::new(q)
            .find(text.into(), separator.into(), limit)
            .iter()
            .flat_map(|m| [m.line, m.column, m.length])
            .collect()
    }

    fn replace(text: &str, separator: &str, q: SearchQuery, template: &str) -> (String, u32) {
        let result = Searcher::new(q).replace(text.into(), separator.into(), template.into());
        (result.text, result.count)
    }

    #[test]
    fn reports_lines_and_columns_on_the_files_own_separator() {
        let text = "x\r\nab needle\r\nfoo\r\nbar\nbaz";
        assert_eq!(
            find(text, "\r\n", query("needle", true, false), 10),
            [2, 3, 6]
        );
        assert_eq!(
            find(text, "\r\n", query("foo\\nbar", true, true), 10),
            [3, 0, 7]
        );
        assert_eq!(
            find(text, "\r\n", query("bar\\nbaz", true, true), 10),
            [4, 0, 7]
        );
    }

    #[test]
    fn finds_nothing_with_a_zero_limit() {
        assert!(find("a a", "\n", query("a", true, false), 0).is_empty());
    }

    #[test]
    fn an_empty_separator_means_newline_when_replacing() {
        assert_eq!(
            replace("a\nb", "", query("a", true, false), "x\ny"),
            ("x\ny\nb".into(), 1)
        );
        let single = Searcher::new(query("a", true, false)).replace_match(
            "a\nb".into(),
            String::new(),
            1,
            0,
            "x\ny".into(),
        );
        assert_eq!(single.as_deref(), Some("x\ny\nb"));
    }

    #[test]
    fn stops_at_the_limit() {
        assert_eq!(
            find("a a a a", "\n", query("a", true, false), 2),
            [1, 0, 1, 1, 2, 1]
        );
    }

    #[test]
    fn normalizes_literal_searches_and_preserves_utf16_positions() {
        assert_eq!(
            find("A needle NEEDLE", "\n", query("NEEDLE", false, false), 10),
            [1, 2, 6, 1, 9, 6]
        );
        assert_eq!(
            find("café cafe\u{301}", "\n", query("café", true, false), 10),
            [1, 0, 4, 1, 5, 5]
        );
        assert_eq!(find("😀a😀", "\n", query("a", true, false), 10), [1, 2, 1]);
    }

    #[test]
    fn replaces_across_lines_and_keeps_the_separator() {
        let text = "one\r\ntwo\r\nthree\r\n";
        let q = query("one\\ntwo", true, true);
        assert_eq!(
            replace(text, "\r\n", q.clone(), "1\\n2\\n"),
            ("1\r\n2\r\n\r\nthree\r\n".into(), 1)
        );
        assert_eq!(
            replace(text, "\r\n", query("two\\nthree", true, true), "[$&]").0,
            "one\r\n[two\r\nthree]\r\n"
        );
        assert_eq!(
            replace(text, "\r\n", query("zzz", true, false), "y"),
            (text.into(), 0)
        );
    }

    #[test]
    fn expands_regex_replacements_and_preserves_literal_templates() {
        let text = "user@example other@host";
        assert_eq!(
            replace(text, "\n", query("(\\w+)@(\\w+)", true, true), "$2@$1").0,
            "example@user host@other"
        );
        assert_eq!(
            replace(
                "needle",
                "\n",
                query("needle", true, true),
                "[$&] $$ $9 $01"
            )
            .0,
            "[needle] $ $9 $01"
        );
        assert_eq!(
            replace("needle", "\n", query("needle", true, false), "$1\\n").0,
            "$1\\n"
        );
    }

    #[test]
    fn uses_javascript_regex_syntax() {
        let q = query("n[e]+dle(?<end>s?)\\b", true, true);
        assert!(Searcher::new(q.clone()).validation_error().is_none());
        assert_eq!(
            find("needle Needle needles", "\n", q, 10),
            [1, 0, 6, 1, 14, 7]
        );
        // Valid ICU (possessive quantifier), invalid JavaScript.
        assert!(
            Searcher::new(query("a++", false, true))
                .validation_error()
                .is_some()
        );
    }

    #[test]
    fn rejects_invalid_patterns() {
        assert!(
            Searcher::new(query("(", true, true))
                .validation_error()
                .unwrap()
                .contains("regular expression")
        );
        assert!(
            Searcher::new(query("(", true, false))
                .validation_error()
                .is_none()
        );
        assert!(find("(", "\n", query("(", true, true), 10).is_empty());
    }
}
