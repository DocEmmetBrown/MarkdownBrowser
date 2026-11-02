import type { BlockContext, InlineContext, Line, MarkdownConfig } from "@lezer/markdown"
import { tags } from "@lezer/highlight"

const DOLLAR = 36
const BACKSLASH = 92

function isSpace(ch: number): boolean {
  return ch === 32 || ch === 9 || ch === 10 || ch === 13 || ch === -1
}

function isDigit(ch: number): boolean {
  return ch >= 48 && ch <= 57
}

/** GitHub-style `$inline$` and `$$block$$` math. */
export const MathSyntax: MarkdownConfig = {
  defineNodes: [
    { name: "InlineMath", style: tags.special(tags.string) },
    { name: "InlineMathMark", style: tags.processingInstruction },
    { name: "MathBlock", block: true },
    { name: "MathBlockMark", style: tags.processingInstruction },
  ],
  parseInline: [
    {
      name: "InlineMath",
      parse(cx: InlineContext, next: number, pos: number): number {
        if (next !== DOLLAR || cx.char(pos + 1) === DOLLAR || isSpace(cx.char(pos + 1))) return -1
        for (let i = pos + 1; i < cx.end; i++) {
          const ch = cx.char(i)
          if (ch === BACKSLASH) {
            i++
            continue
          }
          if (ch !== DOLLAR) continue
          // "$5 and $6" is money, not math.
          if (isSpace(cx.char(i - 1)) || isDigit(cx.char(i + 1))) return -1
          return cx.addElement(
            cx.elt("InlineMath", pos, i + 1, [cx.elt("InlineMathMark", pos, pos + 1), cx.elt("InlineMathMark", i, i + 1)]),
          )
        }
        return -1
      },
      before: "Emphasis",
    },
  ],
  parseBlock: [
    {
      name: "MathBlock",
      parse(cx: BlockContext, line: Line): boolean {
        if (!line.text.startsWith("$$", line.pos)) return false
        const start = cx.lineStart + line.pos
        const marks = [cx.elt("MathBlockMark", start, start + 2)]
        const rest = line.text.slice(line.pos + 2).trimEnd()
        if (rest.length > 2 && rest.endsWith("$$")) {
          const close = cx.lineStart + line.text.lastIndexOf("$$")
          marks.push(cx.elt("MathBlockMark", close, close + 2))
          const end = cx.lineStart + line.text.length
          cx.nextLine()
          cx.addElement(cx.elt("MathBlock", start, end, marks))
          return true
        }
        let end = cx.lineStart + line.text.length
        // Line.depth is not in the public typings, but is how built-in block parsers detect container exits.
        while (cx.nextLine() && (line as unknown as { depth: number }).depth >= cx.depth) {
          end = cx.lineStart + line.text.length
          if (line.text.trimEnd().endsWith("$$")) {
            const close = cx.lineStart + line.text.lastIndexOf("$$")
            marks.push(cx.elt("MathBlockMark", close, close + 2))
            cx.nextLine()
            break
          }
        }
        cx.addElement(cx.elt("MathBlock", start, end, marks))
        return true
      },
      before: "FencedCode",
    },
  ],
}
