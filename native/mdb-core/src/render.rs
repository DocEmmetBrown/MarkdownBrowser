use std::{collections::HashMap, sync::LazyLock};

use comrak::nodes::NodeValue;
use scraper::{Html, Node};
use syntect::{easy::HighlightLines, highlighting::ThemeSet, parsing::SyntaxSet};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RenderError {
    #[error("{message}")]
    Failed { message: String },
}

fn failed(error: impl std::fmt::Display) -> RenderError {
    RenderError::Failed {
        message: error.to_string(),
    }
}

#[derive(Debug, uniffi::Record)]
pub struct RenderNode {
    pub parent: Option<u32>,
    pub tag: String,
    pub text: String,
    pub attributes: HashMap<String, String>,
}

#[uniffi::export]
pub fn render_markdown(text: String) -> Result<Vec<RenderNode>, RenderError> {
    if text.len() > 5_000_000 {
        return Err(failed("Preview exceeds the 5 MB rendering limit"));
    }
    let mut options = crate::markdown::options();
    options.render.r#unsafe = true;
    options.render.sourcepos = true;
    let map = crate::markdown::SourceMap::new(&text);
    let arena = comrak::Arena::new();
    let root = comrak::parse_document(&arena, &text, &options);
    let mut origins = Vec::new();
    for node in root.descendants() {
        let mut data = node.data.borrow_mut();
        let position = data.sourcepos;
        let literal = match &mut data.value {
            NodeValue::HtmlBlock(block) => &mut block.literal,
            NodeValue::HtmlInline(literal) => literal,
            _ => continue,
        };
        let offsets = text
            .get(map.bytes(position))
            .and_then(|raw| html_offsets(raw, literal, map.range(position).0));
        *literal = annotate_html(literal, offsets.as_deref(), &mut origins)?;
    }
    let mut html = String::new();
    comrak::format_html(root, &options, &mut html).map_err(failed)?;
    let clean = ammonia::Builder::default()
        .add_tags(["details", "summary", "video", "source"])
        .add_tag_attributes("code", ["class"])
        .add_tag_attributes("div", ["class"])
        .add_tag_attributes("p", ["class"])
        .add_tag_attributes("span", ["data-math-style"])
        .add_tag_attributes("img", ["width", "height"])
        .add_tag_attributes("video", ["src", "controls", "poster"])
        .add_tag_attributes("source", ["src", "type"])
        .add_generic_attributes(["id", "name", "data-sourcepos", "data-mdb-origin"])
        .url_schemes(["http", "https", "mailto", "file"].into())
        .clean(&html)
        .to_string();
    let document = Html::parse_fragment(&clean);
    let mut output = Vec::new();
    let mut stack = vec![(document.tree.root(), None, 0)];
    while let Some((node, parent, depth)) = stack.pop() {
        if depth > 128 || output.len() >= 100_000 {
            return Err(failed(
                "Preview exceeds the nesting or node limit; use the source editor",
            ));
        }
        let record = match node.value() {
            Node::Element(element) => {
                let mut attributes: HashMap<String, String> = element
                    .attrs()
                    .map(|(key, value)| (key.to_owned(), value.to_owned()))
                    .collect();
                if let Some(start) = attributes
                    .get("data-sourcepos")
                    .and_then(|value| map.start(value))
                {
                    attributes.insert("source-start".into(), start.to_string());
                }
                if let Some(origin) = attributes
                    .remove("data-mdb-origin")
                    .and_then(|value| value.parse::<usize>().ok())
                    .and_then(|index| origins.get(index))
                    .and_then(Option::as_ref)
                {
                    attributes.insert("source-start".into(), origin.start.to_string());
                    attributes.insert("source-end".into(), origin.end.to_string());
                    if origin.text {
                        attributes.insert("source-text".into(), "true".into());
                    }
                }
                Some(RenderNode {
                    parent,
                    tag: element.name().to_owned(),
                    text: String::new(),
                    attributes,
                })
            }
            Node::Text(text) => Some(RenderNode {
                parent,
                tag: "#text".into(),
                text: text.to_string(),
                attributes: HashMap::new(),
            }),
            _ => None,
        };
        let child_parent = if let Some(record) = record {
            let index = output.len() as u32;
            output.push(record);
            Some(index)
        } else {
            parent
        };
        for child in node.children().rev() {
            stack.push((child, child_parent, depth + 1));
        }
    }
    Ok(output)
}

struct HtmlOrigin {
    start: u32,
    end: u32,
    text: bool,
}

fn html_offsets(raw: &str, literal: &str, start: u32) -> Option<Vec<u32>> {
    let exact = raw.trim_end_matches(['\r', '\n']) == literal.trim_end_matches(['\r', '\n']);
    let mut normalized = String::new();
    let mut offsets = vec![start];
    let mut position = start;
    let mut chars = raw.chars().peekable();
    while let Some(mut character) = chars.next() {
        position += character.len_utf16() as u32;
        if character == '\r' && !exact {
            if chars.peek() == Some(&'\n') {
                chars.next();
                position += 1;
            }
            character = '\n';
        }
        normalized.push(character);
        offsets.resize(normalized.len(), *offsets.last().unwrap());
        offsets.push(position);
    }
    if normalized.trim_end_matches(['\r', '\n']) != literal.trim_end_matches(['\r', '\n']) {
        return None;
    }
    offsets.resize(literal.len() + 1, position);
    Some(offsets)
}

// Annotate a rendering copy, not the document. Token boundaries respect quoted
// attributes and raw-text elements; the HTML parser still decides the DOM.
fn annotate_html(
    html: &str,
    offsets: Option<&[u32]>,
    origins: &mut Vec<Option<HtmlOrigin>>,
) -> Result<String, RenderError> {
    let mut output = String::new();
    let mut cursor = 0;
    let mut raw_text: Option<String> = None;
    let mut add_origin = |start: usize, end: usize, text: bool| {
        if origins.len() >= 100_000 {
            return Err(failed(
                "Preview exceeds the source mapping node limit; use the source editor",
            ));
        }
        let index = origins.len();
        origins.push(offsets.map(|offsets| HtmlOrigin {
            start: offsets[start],
            end: offsets[end],
            text,
        }));
        Ok(index)
    };
    while cursor < html.len() {
        if html[cursor..].starts_with("<!--") {
            let end = html[cursor + 4..]
                .find("-->")
                .map_or(html.len(), |end| cursor + 4 + end + 3);
            output.push_str(&html[cursor..end]);
            cursor = end;
            continue;
        }
        if raw_text.is_none()
            && (html[cursor..].starts_with("<!") || html[cursor..].starts_with("<?"))
        {
            let end = html[cursor..]
                .find('>')
                .map_or(html.len(), |end| cursor + end + 1);
            output.push_str(&html[cursor..end]);
            cursor = end;
            continue;
        }
        if html.as_bytes()[cursor] == b'<' {
            let closing = html[cursor..].starts_with("</");
            let name_start = cursor + if closing { 2 } else { 1 };
            let mut name_end = name_start;
            while name_end < html.len()
                && (html.as_bytes()[name_end].is_ascii_alphanumeric()
                    || matches!(html.as_bytes()[name_end], b'-' | b':' | b'_'))
            {
                name_end += 1;
            }
            let valid =
                html.as_bytes()
                    .get(name_start)
                    .is_some_and(u8::is_ascii_alphabetic)
                    && html.as_bytes().get(name_end).is_some_and(|byte| {
                        byte.is_ascii_whitespace() || matches!(byte, b'>' | b'/')
                    });
            let name = html
                .get(name_start..name_end)
                .unwrap_or("")
                .to_ascii_lowercase();
            if raw_text.is_some() && !(valid && closing && raw_text.as_ref() == Some(&name)) {
                let end = html[cursor + 1..]
                    .find('<')
                    .map_or(html.len(), |end| cursor + 1 + end);
                output.push_str(&html[cursor..end]);
                cursor = end;
                continue;
            }
            let mut quote = None;
            let mut terminated = false;
            let mut end = name_end;
            while end < html.len() {
                let byte = html.as_bytes()[end];
                end += 1;
                match (quote, byte) {
                    (Some(value), byte) if value == byte => quote = None,
                    (None, b'\'' | b'"') => quote = Some(byte),
                    (None, b'>') => {
                        terminated = true;
                        break;
                    }
                    _ => (),
                }
            }
            if valid && !terminated {
                output.push_str(&html[cursor..]);
                break;
            }
            if valid && terminated {
                output.push_str(&html[cursor..name_end]);
                if closing {
                    raw_text = None;
                } else {
                    let origin = add_origin(cursor, end, false)?;
                    // First duplicate attribute wins in the HTML parser. Raw
                    // input cannot forge either provenance or Comrak positions.
                    output.push_str(&format!(
                        " data-mdb-origin=\"{origin}\" data-sourcepos=\"\""
                    ));
                    if matches!(
                        name.as_str(),
                        "script"
                            | "style"
                            | "textarea"
                            | "title"
                            | "xmp"
                            | "iframe"
                            | "noembed"
                            | "noframes"
                            | "plaintext"
                    ) {
                        raw_text = Some(name);
                    }
                }
                output.push_str(&html[name_end..end]);
                cursor = end;
                continue;
            }
        }
        let next = cursor + html[cursor..].chars().next().unwrap().len_utf8();
        let end = html[next..].find('<').map_or(html.len(), |end| next + end);
        let text = &html[cursor..end];
        if offsets.is_some() && raw_text.is_none() && !text.trim().is_empty() {
            let body = if end == html.len() {
                text.trim_end_matches(['\r', '\n'])
            } else {
                text
            };
            let origin = add_origin(cursor, cursor + body.len(), true)?;
            output.push_str(&format!("<span data-mdb-origin=\"{origin}\">{body}</span>"));
            output.push_str(&text[body.len()..]);
        } else {
            output.push_str(text);
        }
        cursor = end;
    }
    Ok(output)
}

static SYNTAXES: LazyLock<SyntaxSet> = LazyLock::new(two_face::syntax::extra_newlines);
static THEMES: LazyLock<ThemeSet> = LazyLock::new(ThemeSet::load_defaults);

#[derive(Debug, uniffi::Record)]
pub struct CodeHighlight {
    pub start: u32,
    pub length: u32,
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

/// Splits after each `\r\n`, `\n` or lone `\r`, keeping the terminator on its line.
fn lines_with_endings(text: &str) -> impl Iterator<Item = &str> {
    let bytes = text.as_bytes();
    let mut start = 0;
    std::iter::from_fn(move || {
        if start == bytes.len() {
            return None;
        }
        let mut end = start;
        while end < bytes.len() && bytes[end] != b'\n' && bytes[end] != b'\r' {
            end += 1;
        }
        if end < bytes.len() {
            end += if bytes[end] == b'\r' && bytes.get(end + 1) == Some(&b'\n') {
                2
            } else {
                1
            };
        }
        let line = &text[start..end];
        start = end;
        Some(line)
    })
}

#[uniffi::export]
pub fn highlight_source(
    text: String,
    language: String,
    dark: bool,
) -> Result<Vec<CodeHighlight>, RenderError> {
    let syntax = SYNTAXES
        .find_syntax_by_token(&language)
        .unwrap_or_else(|| SYNTAXES.find_syntax_plain_text());
    let theme = &THEMES.themes[if dark {
        "base16-ocean.dark"
    } else {
        "InspiredGitHub"
    }];
    let mut highlighter = HighlightLines::new(syntax, theme);
    let mut output = Vec::new();
    let mut offset = 0;
    for line in lines_with_endings(&text) {
        // syntect only ends a line at `\n`; swapping a lone `\r` keeps the UTF-16 length.
        let line = match line.strip_suffix('\r') {
            Some(body) => format!("{body}\n"),
            None => line.to_owned(),
        };
        for (style, part) in highlighter
            .highlight_line(&line, &SYNTAXES)
            .map_err(failed)?
        {
            let length = part.encode_utf16().count() as u32;
            output.push(CodeHighlight {
                start: offset,
                length,
                red: style.foreground.r,
                green: style.foreground.g,
                blue: style.foreground.b,
            });
            offset += length;
        }
    }
    Ok(output)
}

#[uniffi::export]
pub fn render_diagram(source: String, dark: bool) -> Result<Vec<u8>, RenderError> {
    if source.len() > 100_000 {
        return Err(failed("Diagram exceeds the 100 KB rendering limit"));
    }
    let mut options = mermaid_rs_renderer::RenderOptions::default();
    if dark {
        options.theme.background = "#0d1117".into();
        options.theme.text_color = "#e6edf3".into();
        options.theme.primary_color = "#161b22".into();
        options.theme.primary_text_color = "#e6edf3".into();
        options.theme.line_color = "#8b949e".into();
    }
    let svg = mermaid_rs_renderer::render_with_options(&source, options).map_err(failed)?;
    rasterize_svg(svg.into_bytes())
}

static FONTS: LazyLock<std::sync::Arc<resvg::usvg::fontdb::Database>> = LazyLock::new(|| {
    let mut database = resvg::usvg::fontdb::Database::new();
    database.load_system_fonts();
    std::sync::Arc::new(database)
});

#[uniffi::export]
pub fn rasterize_svg(source: Vec<u8>) -> Result<Vec<u8>, RenderError> {
    if source.len() > 8_000_000 {
        return Err(failed("SVG exceeds the 8 MB rendering limit"));
    }
    let mut options = resvg::usvg::Options {
        fontdb: FONTS.clone(),
        ..Default::default()
    };
    // SVGs never resolve embedded paths, URLs or data images outside PathPolicy.
    options.image_href_resolver.resolve_string = Box::new(|_, _| None);
    options.image_href_resolver.resolve_data = Box::new(|_, _, _| None);
    let tree = resvg::usvg::Tree::from_data(&source, &options).map_err(failed)?;
    let size = tree.size();
    let scale = (2048.0 / size.width().max(size.height())).min(2.0);
    let width = (size.width() * scale).ceil().max(1.0) as u32;
    let height = (size.height() * scale).ceil().max(1.0) as u32;
    let mut pixels = resvg::tiny_skia::Pixmap::new(width, height)
        .ok_or_else(|| failed("Cannot allocate the diagram image"))?;
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::from_scale(scale, scale),
        &mut pixels.as_mut(),
    );
    pixels.encode_png().map_err(failed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitized_html_keeps_details_and_rejects_active_content() {
        let source = "<details><summary>More</summary><img src=\"../logo.svg\" onerror=\"alert(1)\"><script>evil()</script><a href=\"javascript:evil()\">bad</a></details>";
        let nodes = render_markdown(source.into()).unwrap();
        assert!(nodes.iter().any(|node| node.tag == "details"));
        assert!(nodes.iter().any(|node| node.tag == "summary"));
        assert!(
            nodes
                .iter()
                .any(|node| node.attributes.get("src") == Some(&"../logo.svg".into()))
        );
        assert!(nodes.iter().all(|node| {
            node.tag != "script"
                && !node.text.contains("evil()")
                && !node.attributes.contains_key("onerror")
                && node
                    .attributes
                    .get("href")
                    .is_none_or(|value| !value.starts_with("javascript:"))
        }));
    }

    #[test]
    fn raw_html_origins_are_exact_and_cannot_be_forged() {
        let source = "# 😀\r\n\r\n<div title=\"a > b\">\r\n<p>same &amp; 😀</p>\r\n<p data-mdb-origin=\"0\" data-sourcepos=\"1:1-1:1\">same &amp; 😀</p>\r\n<img src=\"local.png\"></div>";
        let nodes = render_markdown(source.into()).unwrap();
        let paragraphs: Vec<_> = nodes.iter().filter(|node| node.tag == "p").collect();
        assert_eq!(paragraphs.len(), 2);
        for (paragraph, (byte, _)) in paragraphs.iter().zip(source.match_indices("<p")) {
            assert_eq!(
                paragraph.attributes["source-start"],
                source[..byte].encode_utf16().count().to_string()
            );
        }
        let spans: Vec<_> = nodes
            .iter()
            .filter(|node| {
                node.attributes
                    .get("source-text")
                    .is_some_and(|value| value == "true")
            })
            .collect();
        assert_eq!(spans.len(), 2);
        for (span, (byte, text)) in spans.iter().zip(source.match_indices("same &amp; 😀")) {
            let start = source[..byte].encode_utf16().count();
            assert_eq!(span.attributes["source-start"], start.to_string());
            assert_eq!(
                span.attributes["source-end"],
                (start + text.encode_utf16().count()).to_string()
            );
        }
    }

    #[test]
    fn raw_html_annotation_preserves_visible_text_and_sanitization() {
        for source in [
            "<div>😀 &amp; same <b title='a > b'>same</b><!-- invisible --></div>",
            "<table><tr><td>one &lt; two</td><td>😀</td></tr></table>",
            "<div><script>evil('<b>hidden</b>')</script><style>b { color: red }</style>visible</div>",
            "<div><textarea>a &lt; b</textarea><img title='x > y' src='test.png'>after</div>",
            "<div><script>var x = '<b title=\"';</script><p>visible</p></div>",
            "<!DOCTYPE foo <div data-mdb-origin='0'>>\n\n<div>visible</div>",
            "> <div>\n> quoted &amp; 😀\n> </div>",
        ] {
            let mut options = crate::markdown::options();
            options.render.r#unsafe = true;
            let baseline = ammonia::clean(&comrak::markdown_to_html(source, &options));
            let expected = Html::parse_fragment(&baseline)
                .root_element()
                .text()
                .collect::<String>();
            let rendered = render_markdown(source.into()).unwrap();
            let actual: String = rendered.iter().map(|node| node.text.as_str()).collect();
            assert_eq!(actual, expected, "{source}");
        }
    }

    #[test]
    fn preview_bounds_nesting_and_rejects_overflowing_source_positions() {
        let source = format!("{}text{}", "<span>".repeat(150), "</span>".repeat(150));
        assert!(render_markdown(source).is_err());
        let source = "first\n\n<span data-sourcepos=\"2:18446744073709551615-2:18446744073709551615\">text</span>";
        assert!(render_markdown(source.into()).is_ok());
    }

    #[test]
    fn code_highlighting_preserves_utf16_ranges_and_line_endings() {
        let source = "let greeting = \"😀\";\r\n// comment\r\n";
        let spans = highlight_source(source.into(), "rs".into(), false).unwrap();
        assert_eq!(
            spans.iter().map(|span| span.length).sum::<u32>(),
            source.encode_utf16().count() as u32
        );
        assert!(
            spans
                .windows(2)
                .any(|pair| (pair[0].red, pair[0].green, pair[0].blue)
                    != (pair[1].red, pair[1].green, pair[1].blue))
        );
    }

    #[test]
    fn bare_cr_line_endings_highlight_per_line() {
        let lf = highlight_source("// c\nlet x = 1;\n".into(), "rs".into(), false).unwrap();
        let cr = highlight_source("// c\rlet x = 1;\r".into(), "rs".into(), false).unwrap();
        assert_eq!(
            cr.iter().map(|span| span.length).sum::<u32>(),
            "// c\rlet x = 1;\r".encode_utf16().count() as u32
        );
        let spans = |highlights: &[CodeHighlight]| {
            highlights
                .iter()
                .map(|h| (h.start, h.length, h.red, h.green, h.blue))
                .collect::<Vec<_>>()
        };
        assert_eq!(spans(&cr), spans(&lf));
    }

    #[test]
    fn common_fenced_languages_have_token_colors_in_both_themes() {
        for (language, source) in [
            (
                "swift",
                "struct Greeting {\r\n    let name: String = \"😀\"\r\n}\r\n",
            ),
            ("typescript", "const count: number = 42; // counter\n"),
            ("rust", "let value: u32 = 42; // counter\n"),
            ("python", "value = \"hello\" # counter\n"),
            ("javascript", "const value = 42; // counter\n"),
        ] {
            for dark in [false, true] {
                let spans = highlight_source(source.into(), language.into(), dark).unwrap();
                let colors: std::collections::HashSet<_> = spans
                    .iter()
                    .map(|span| (span.red, span.green, span.blue))
                    .collect();
                assert!(
                    colors.len() >= 3,
                    "{language} (dark={dark}) has only {colors:?}"
                );
                assert_eq!(
                    spans.iter().map(|span| span.length).sum::<u32>(),
                    source.encode_utf16().count() as u32
                );
            }
        }
    }

    #[test]
    fn diagram_renders_without_browser_and_rejects_invalid_input() {
        let image = render_diagram("flowchart LR\nA[Start] --> B[End]".into(), false).unwrap();
        assert!(image.starts_with(b"\x89PNG"));
        assert!(render_diagram("not a diagram".into(), false).is_err());
    }
}
