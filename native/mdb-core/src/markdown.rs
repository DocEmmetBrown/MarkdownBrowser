//! Markdown structure and original UTF-16 source ranges for the native editor.

use comrak::{
    Arena, Options,
    nodes::{AstNode, ListType, NodeValue, Sourcepos},
    parse_document,
};
use std::collections::{HashMap, HashSet};
use unicode_general_category::{GeneralCategory, get_general_category};

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum MarkdownKind {
    Document,
    Paragraph,
    Heading,
    Quote,
    List,
    Item,
    Task,
    Rule,
    CodeBlock,
    Code,
    Text,
    SoftBreak,
    LineBreak,
    Emphasis,
    Strong,
    Strike,
    Link,
    Image,
    Table,
    TableRow,
    TableCell,
    Html,
    Math,
    Emoji,
    Footnote,
    FootnoteReference,
    Alert,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MarkdownNode {
    pub kind: MarkdownKind,
    pub parent: Option<u32>,
    pub start: u32,
    pub length: u32,
    pub text: String,
    pub destination: String,
    /// A secondary string whose meaning depends on the kind: code block info string; link or image title;
    /// footnote name; footnote reference anchor ID; alert title (or its type name);
    /// for a task, the UTF-16 offset of its checkbox symbol. Empty for other kinds.
    pub detail: String,
    /// A number whose meaning depends on the kind:
    /// heading depth (1 to 6); ordered list start number (0 for a bullet list);
    /// task checked (1) or not (0); table row is a header (1) or not (0);
    /// math is display (1) or inline (0). Zero for other kinds.
    pub level: u32,
}

pub(crate) struct SourceMap {
    lines: Vec<usize>,
    utf16: Vec<u32>,
}

impl SourceMap {
    pub(crate) fn new(text: &str) -> Self {
        let mut lines = vec![0];
        let bytes = text.as_bytes();
        for (index, &byte) in bytes.iter().enumerate() {
            if byte == b'\n' || (byte == b'\r' && bytes.get(index + 1) != Some(&b'\n')) {
                lines.push(index + 1);
            }
        }
        let mut utf16 = vec![0; text.len() + 1];
        let mut offset = 0;
        for (index, character) in text.char_indices() {
            utf16[index..index + character.len_utf8()].fill(offset);
            offset += character.len_utf16() as u32;
            utf16[index + character.len_utf8()] = offset;
        }
        Self { lines, utf16 }
    }

    pub(crate) fn start(&self, position: &str) -> Option<u32> {
        let (line, column) = position.split_once('-')?.0.split_once(':')?;
        let line: usize = line.parse().ok()?;
        let column: usize = column.parse().ok()?;
        let byte = self
            .lines
            .get(line.checked_sub(1)?)?
            .checked_add(column.checked_sub(1)?)?;
        self.utf16.get(byte).copied()
    }

    pub(crate) fn bytes(&self, position: Sourcepos) -> std::ops::Range<usize> {
        let offset = |line: usize, column: usize| {
            self.lines
                .get(line.saturating_sub(1))
                .map(|&start| (start + column).min(self.utf16.len() - 1))
                .unwrap_or(self.utf16.len() - 1)
        };
        offset(position.start.line, position.start.column.saturating_sub(1))
            ..offset(position.end.line, position.end.column)
    }

    pub(crate) fn range(&self, position: Sourcepos) -> (u32, u32) {
        let bytes = self.bytes(position);
        let start = self.utf16[bytes.start];
        let end = self.utf16[bytes.end];
        (start, end.saturating_sub(start))
    }
}

#[uniffi::export]
pub fn parse_markdown(text: String) -> Vec<MarkdownNode> {
    let arena = Arena::new();
    let options = options();
    let root = parse_document(&arena, &text, &options);
    let map = SourceMap::new(&text);
    let mut output = Vec::new();
    let mut stack = vec![(root, None)];
    let mut slugs = HashSet::new();
    let mut next_suffixes = HashMap::new();
    while let Some((node, parent)) = stack.pop() {
        let data = node.data.borrow();
        let (start, length) = map.range(data.sourcepos);
        let mut record = MarkdownNode {
            kind: MarkdownKind::Document,
            parent,
            start,
            length,
            text: String::new(),
            destination: String::new(),
            detail: String::new(),
            level: 0,
        };
        record.kind = match &data.value {
            NodeValue::Document => MarkdownKind::Document,
            NodeValue::Paragraph => MarkdownKind::Paragraph,
            NodeValue::Heading(heading) => {
                record.level = u32::from(heading.level);
                let base = github_slug(&plain_text(node));
                let mut slug = base.clone();
                let count = next_suffixes.entry(base.clone()).or_insert(1_usize);
                while !slugs.insert(slug.clone()) {
                    slug = format!("{base}-{count}");
                    *count += 1;
                }
                record.destination = slug;
                MarkdownKind::Heading
            }
            NodeValue::BlockQuote => MarkdownKind::Quote,
            NodeValue::List(list) => {
                record.level = if list.list_type == ListType::Ordered {
                    list.start as u32
                } else {
                    0
                };
                MarkdownKind::List
            }
            NodeValue::Item(_) => MarkdownKind::Item,
            NodeValue::TaskItem(task) => {
                record.level = u32::from(task.symbol.is_some());
                let (symbol, _) = map.range(task.symbol_sourcepos);
                record.detail = symbol.to_string();
                MarkdownKind::Task
            }
            NodeValue::ThematicBreak(_) => MarkdownKind::Rule,
            NodeValue::CodeBlock(code) => {
                record.text = code.literal.clone();
                record.detail = code.info.clone();
                MarkdownKind::CodeBlock
            }
            NodeValue::Code(code) => {
                record.text = code.literal.clone();
                MarkdownKind::Code
            }
            NodeValue::Text(text) => {
                record.text = text.to_string();
                MarkdownKind::Text
            }
            NodeValue::SoftBreak => MarkdownKind::SoftBreak,
            NodeValue::LineBreak => MarkdownKind::LineBreak,
            NodeValue::Emph(_) => MarkdownKind::Emphasis,
            NodeValue::Strong(_) => MarkdownKind::Strong,
            NodeValue::Strikethrough(_) => MarkdownKind::Strike,
            NodeValue::Link(link) | NodeValue::Image(link) => {
                record.destination = link.url.clone();
                record.detail = link.title.clone();
                if matches!(data.value, NodeValue::Image(_)) {
                    MarkdownKind::Image
                } else {
                    MarkdownKind::Link
                }
            }
            NodeValue::Table(_) => MarkdownKind::Table,
            NodeValue::TableRow(row) => {
                record.level = u32::from(row.header);
                MarkdownKind::TableRow
            }
            NodeValue::TableCell => MarkdownKind::TableCell,
            NodeValue::HtmlBlock(html) => {
                record.text = html.literal.clone();
                MarkdownKind::Html
            }
            NodeValue::HtmlInline(html) => {
                record.text = html.clone();
                MarkdownKind::Html
            }
            NodeValue::Math(math) => {
                record.text = math.literal.clone();
                record.level = u32::from(math.display_math);
                MarkdownKind::Math
            }
            NodeValue::ShortCode(code) => {
                record.text = code.emoji.clone();
                MarkdownKind::Emoji
            }
            NodeValue::FootnoteDefinition(footnote) => {
                record.destination = format!("fn-{}", footnote.name.to_lowercase());
                record.detail = footnote.name.clone();
                MarkdownKind::Footnote
            }
            NodeValue::FootnoteReference(footnote) => {
                record.text = footnote.ix.to_string();
                record.destination = format!("#fn-{}", footnote.name.to_lowercase());
                record.detail = format!("fnref-{}", footnote.name.to_lowercase());
                MarkdownKind::FootnoteReference
            }
            NodeValue::Alert(alert) => {
                record.detail = alert
                    .title
                    .clone()
                    .unwrap_or_else(|| format!("{:?}", alert.alert_type));
                MarkdownKind::Alert
            }
            _ => MarkdownKind::Document,
        };
        drop(data);
        let index = output.len() as u32;
        output.push(record);
        for child in node.reverse_children() {
            stack.push((child, Some(index)));
        }
    }
    output
}

pub(crate) fn options() -> Options<'static> {
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.tasklist = true;
    options.extension.strikethrough = true;
    options.extension.autolink = true;
    options.extension.footnotes = true;
    options.extension.alerts = true;
    options.extension.math_dollars = true;
    options.extension.shortcodes = true;
    options
}

fn plain_text<'a>(node: &'a AstNode<'a>) -> String {
    let mut output = String::new();
    for descendant in node.descendants() {
        match &descendant.data.borrow().value {
            NodeValue::Text(text) => output.push_str(text),
            NodeValue::Code(code) => output.push_str(&code.literal),
            NodeValue::SoftBreak | NodeValue::LineBreak => output.push(' '),
            NodeValue::ShortCode(code) => output.push_str(&code.emoji),
            _ => {}
        }
    }
    output
}

fn github_slug(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .filter(|&ch| {
            ch == '-'
                || ch == ' '
                || matches!(
                    get_general_category(ch),
                    GeneralCategory::UppercaseLetter
                        | GeneralCategory::LowercaseLetter
                        | GeneralCategory::TitlecaseLetter
                        | GeneralCategory::ModifierLetter
                        | GeneralCategory::OtherLetter
                        | GeneralCategory::NonspacingMark
                        | GeneralCategory::SpacingMark
                        | GeneralCategory::EnclosingMark
                        | GeneralCategory::DecimalNumber
                        | GeneralCategory::LetterNumber
                        | GeneralCategory::OtherNumber
                        | GeneralCategory::ConnectorPunctuation
                )
        })
        .map(|ch| if ch == ' ' { '-' } else { ch })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_map_start_rejects_overflowing_and_out_of_range_positions() {
        let map = SourceMap::new("ab\ncd");
        assert_eq!(map.start("2:2-2:2"), Some(4));
        let max = usize::MAX;
        assert_eq!(map.start(&format!("2:{max}-2:{max}")), None);
        assert_eq!(map.start(&format!("{max}:1-{max}:1")), None);
        assert_eq!(map.start("0:1-0:1"), None);
        assert_eq!(map.start("1:0-1:0"), None);
        assert_eq!(map.start("3:1-3:1"), None);
    }

    #[test]
    fn resolves_links_without_treating_code_as_links() {
        let source = "😀 [nested](a(b).md \"Title\")\r\n`[no](bad)`\r\n\r\n[ref][ GUIDE ]\r\n\r\n[guide]: <docs/my guide.md>\r\n";
        let nodes = parse_markdown(source.into());
        let links: Vec<_> = nodes
            .iter()
            .filter(|node| node.kind == MarkdownKind::Link)
            .collect();
        assert_eq!(links.len(), 2);
        assert_eq!(links[0].destination, "a(b).md");
        assert_eq!(links[0].detail, "Title");
        assert_eq!(links[0].start, 3);
        assert_eq!(links[1].destination, "docs/my guide.md");
        let units: Vec<_> = source.encode_utf16().collect();
        let link = links[1];
        assert_eq!(
            String::from_utf16_lossy(
                &units[link.start as usize..(link.start + link.length) as usize]
            ),
            "[ref][ GUIDE ]"
        );
    }

    #[test]
    fn headings_have_structural_duplicate_slugs() {
        let source = "# Hello **world**\n\n```\n# Hello world\n```\n\n> # Hello world\n\nHello world\n===\n\n# Hello world-1\n\n# Hello world-4\n\n# Hello world\n\n# Hello world\n\n# Hello world-1\n";
        let headings: Vec<_> = parse_markdown(source.into())
            .into_iter()
            .filter(|node| node.kind == MarkdownKind::Heading)
            .map(|node| node.destination)
            .collect();
        assert_eq!(
            headings,
            [
                "hello-world",
                "hello-world-1",
                "hello-world-2",
                "hello-world-1-1",
                "hello-world-4",
                "hello-world-3",
                "hello-world-5",
                "hello-world-1-2"
            ]
        );
    }

    #[test]
    fn parses_gfm_extensions_and_keeps_task_symbol_range() {
        let source = "- [ ] Task :tada:\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\nText[^note] $x^2$\n\n[^note]: Footnote\n\n> [!NOTE]\n> Alert\n";
        let nodes = parse_markdown(source.into());
        for kind in [
            MarkdownKind::Task,
            MarkdownKind::Table,
            MarkdownKind::Emoji,
            MarkdownKind::Math,
            MarkdownKind::Footnote,
            MarkdownKind::Alert,
        ] {
            assert!(nodes.iter().any(|node| node.kind == kind), "{kind:?}");
        }
        let task = nodes
            .iter()
            .find(|node| node.kind == MarkdownKind::Task)
            .unwrap();
        let offset: usize = task.detail.parse().unwrap();
        assert_eq!(&source[offset..offset + 1], " ");
    }
}
