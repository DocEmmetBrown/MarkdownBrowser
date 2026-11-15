use std::{collections::HashMap, sync::LazyLock};

use scraper::{Html, Node};
use syntect::{
    easy::HighlightLines, highlighting::ThemeSet, parsing::SyntaxSet, util::LinesWithEndings,
};

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
    let html = comrak::markdown_to_html(&text, &options);
    let clean = ammonia::Builder::default()
        .add_tags(["details", "summary", "video", "source"])
        .add_tag_attributes("code", ["class"])
        .add_tag_attributes("div", ["class"])
        .add_tag_attributes("p", ["class"])
        .add_tag_attributes("span", ["data-math-style"])
        .add_tag_attributes("img", ["width", "height"])
        .add_tag_attributes("video", ["src", "controls", "poster"])
        .add_tag_attributes("source", ["src", "type"])
        .add_generic_attributes(["id", "name", "data-sourcepos"])
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

static SYNTAXES: LazyLock<SyntaxSet> = LazyLock::new(SyntaxSet::load_defaults_newlines);
static THEMES: LazyLock<ThemeSet> = LazyLock::new(ThemeSet::load_defaults);

#[derive(Debug, uniffi::Record)]
pub struct CodeHighlight {
    pub start: u32,
    pub length: u32,
    pub red: u8,
    pub green: u8,
    pub blue: u8,
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
    for line in LinesWithEndings::from(&text) {
        for (style, part) in highlighter
            .highlight_line(line, &SYNTAXES)
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
    fn diagram_renders_without_browser_and_rejects_invalid_input() {
        let image = render_diagram("flowchart LR\nA[Start] --> B[End]".into(), false).unwrap();
        assert!(image.starts_with(b"\x89PNG"));
        assert!(render_diagram("not a diagram".into(), false).is_err());
    }
}
