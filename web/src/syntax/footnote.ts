import type { BlockContext, InlineContext, Line, MarkdownConfig } from "@lezer/markdown"
import { tags } from "@lezer/highlight"

const BRACKET_OPEN = 91
const BRACKET_CLOSE = 93
const CARET = 94

const definitionStart = /^\[\^([^\]\s]+)\]:/
// Lines that start another block end a footnote definition unless indented into it.
const blockStart = /^(#{1,6}(\s|$)|>|[-*+](\s|$)|\d{1,9}[.)](\s|$)|```|~~~|\||<|\$\$)/

function isSpace(ch: number): boolean {
  return ch === 32 || ch === 9 || ch === 10 || ch === 13 || ch === -1
}

function startsDefinition(line: Line): boolean {
  return definitionStart.test(line.text.slice(line.pos))
}

/** GitHub footnotes: `[^label]` references and `[^label]: text` definitions. */
export const FootnoteSyntax: MarkdownConfig = {
  defineNodes: [
    { name: "FootnoteReference", style: tags.link },
    { name: "FootnoteMark", style: tags.processingInstruction },
    { name: "FootnoteLabel", style: tags.labelName },
    { name: "FootnoteDefinition", block: true },
    { name: "FootnoteDefinitionMark", style: tags.processingInstruction },
  ],
  parseInline: [
    {
      name: "FootnoteReference",
      parse(cx: InlineContext, next: number, pos: number): number {
        if (next !== BRACKET_OPEN || cx.char(pos + 1) !== CARET) return -1
        let end = pos + 2
        for (; end < cx.end; end++) {
          const ch = cx.char(end)
          if (ch === BRACKET_CLOSE) break
          if (isSpace(ch) || ch === BRACKET_OPEN) return -1
        }
        if (end === pos + 2 || end >= cx.end) return -1
        return cx.addElement(
          cx.elt("FootnoteReference", pos, end + 1, [
            cx.elt("FootnoteMark", pos, pos + 2),
            cx.elt("FootnoteLabel", pos + 2, end),
            cx.elt("FootnoteMark", end, end + 1),
          ]),
        )
      },
      before: "Link",
    },
  ],
  parseBlock: [
    {
      name: "FootnoteDefinition",
      parse(cx: BlockContext, line: Line): boolean {
        const match = definitionStart.exec(line.text.slice(line.pos))
        if (!match) return false
        const start = cx.lineStart + line.pos
        const markEnd = start + match[0].length
        const mark = cx.elt("FootnoteDefinitionMark", start, markEnd, [
          cx.elt("FootnoteLabel", start + 2, start + 2 + match[1].length),
        ])
        let content = line.text.slice(line.pos + match[0].length)
        let end = cx.lineStart + line.text.length
        // Line.depth is not in the public typings, but is how built-in block parsers detect container exits.
        while (cx.nextLine()) {
          if ((line as unknown as { depth: number }).depth < cx.depth || line.next === -1 || startsDefinition(line)) break
          if (line.indent < line.baseIndent + 4 && blockStart.test(line.text.slice(line.pos))) break
          content += "\n" + line.text
          end = cx.lineStart + line.text.length
        }
        cx.addElement(cx.elt("FootnoteDefinition", start, end, [mark, ...cx.parser.parseInline(content, markEnd)]))
        return true
      },
      endLeaf: (_cx, line) => startsDefinition(line),
      before: "LinkReference",
    },
  ],
}
