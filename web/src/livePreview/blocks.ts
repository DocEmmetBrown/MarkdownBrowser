import { EditorState, StateField, type Range } from "@codemirror/state"
import { Decoration, EditorView, type DecorationSet } from "@codemirror/view"
import { syntaxTree } from "@codemirror/language"
import type { SyntaxNodeRef } from "@lezer/common"
import { BlockWidget, type BlockKind } from "./widgets"
import { diagramThemeField, focusedField, linesTouch, setDiagramTheme, setFocused, setRevealSelection } from "./state"

const containerNodes = new Set(["Document", "BulletList", "OrderedList", "ListItem"])

// Tags that commonly wrap Markdown, e.g. `<details>` around a blank-line-separated body.
const wrapperTags = new Set([
  "article", "aside", "blockquote", "center", "details", "div", "dl", "figure", "footer", "header", "main",
  "nav", "ol", "section", "table", "ul",
])
const tagPatterns = new Map<string, RegExp>()

/** Opening minus closing `tag`s in `text` (self-closing tags don't count). */
function tagBalance(text: string, tag: string): number {
  let pattern = tagPatterns.get(tag)
  if (!pattern) tagPatterns.set(tag, (pattern = new RegExp(`<(/?)${tag}(?=[\\s/>])[^>]*?(/?)>`, "gi")))
  let depth = 0
  for (const match of text.matchAll(pattern)) {
    if (match[1]) depth--
    else if (!match[2]) depth++
  }
  return depth
}

/**
 * End of an HTML block, extended to the sibling HTML block that closes its wrapper tag:
 * CommonMark ends HTML blocks at a blank line, which splits `<details>` from its Markdown body.
 */
export function htmlBlockEnd(state: EditorState, node: SyntaxNodeRef): number {
  if (node.name !== "HTMLBlock") return node.to
  const text = state.sliceDoc(node.from, node.to)
  const tag = /^\s*<([a-z][a-z0-9-]*)(?=[\s/>])/i.exec(text)?.[1].toLowerCase()
  if (!tag || !wrapperTags.has(tag)) return node.to
  let depth = tagBalance(text, tag)
  if (depth <= 0) return node.to
  for (let sibling = node.node.nextSibling; sibling; sibling = sibling.nextSibling) {
    if (sibling.name !== "HTMLBlock") continue
    depth += tagBalance(state.sliceDoc(sibling.from, sibling.to), tag)
    if (depth <= 0) return sibling.to
  }
  return node.to
}

export function blockKind(state: EditorState, node: SyntaxNodeRef): BlockKind | null {
  switch (node.name) {
    case "Table":
      return "table"
    case "HTMLBlock":
    case "CommentBlock":
      return "html"
    case "MathBlock":
      return "math"
    case "FencedCode": {
      const info = node.node.getChild("CodeInfo")
      const language = info ? state.sliceDoc(info.from, info.to).trim().toLowerCase() : ""
      if (language === "mermaid") return "mermaid"
      if (language === "math") return "math"
      return null
    }
    default:
      return null
  }
}

export interface BlockSpan {
  lineFrom: number
  lineTo: number
  text: string
}

/** Full lines covered by a block node, with the container indentation stripped. */
export function blockSpan(state: EditorState, from: number, to: number): BlockSpan {
  const first = state.doc.lineAt(from)
  let last = state.doc.lineAt(to)
  if (to === last.from && last.number > first.number) last = state.doc.line(last.number - 1)
  const indent = from - first.from
  const lines: string[] = []
  for (let n = first.number; n <= last.number; n++) {
    const text = state.doc.line(n).text
    let strip = 0
    while (strip < indent && strip < text.length && (text[strip] === " " || text[strip] === "\t")) strip++
    lines.push(text.slice(strip))
  }
  return { lineFrom: first.from, lineTo: last.to, text: lines.join("\n") }
}

function blockContent(kind: BlockKind, nodeName: string, text: string): string {
  if (kind === "math" && nodeName === "MathBlock") {
    return text.trim().replace(/^\$\$/, "").replace(/\$\$$/, "").trim()
  }
  if (kind === "mermaid" || kind === "math") {
    const lines = text.split("\n").slice(1)
    if (lines.length > 0 && /^\s*(```|~~~)/.test(lines[lines.length - 1])) lines.pop()
    return lines.join("\n")
  }
  return text
}

function buildBlockDecorations(state: EditorState): DecorationSet {
  const ranges: Range<Decoration>[] = []
  const theme = state.field(diagramThemeField)
  let renderedTo = -1
  let sourceTo = -1
  syntaxTree(state).iterate({
    enter(node) {
      if (containerNodes.has(node.name)) return true
      if (node.from < renderedTo) return false
      const kind = blockKind(state, node)
      if (!kind) return false
      const end = kind === "html" ? htmlBlockEnd(state, node) : node.to
      const span = blockSpan(state, node.from, end)
      const content = blockContent(kind, node.name, span.text)
      const asSource = (kind === "html" && node.from < sourceTo) || linesTouch(state, span.lineFrom, span.lineTo)
      if (!asSource) {
        renderedTo = end
        ranges.push(
          Decoration.replace({ widget: new BlockWidget(kind, content, theme, false), block: true }).range(
            span.lineFrom,
            span.lineTo,
          ),
        )
      } else if (kind === "html") {
        sourceTo = Math.max(sourceTo, end)
      } else if (kind === "mermaid" || kind === "math") {
        ranges.push(
          Decoration.widget({ widget: new BlockWidget(kind, content, theme, true), block: true, side: 1 }).range(
            span.lineTo,
          ),
        )
      }
      return false
    },
  })
  return Decoration.set(ranges, true)
}

export const blockPreviewField = StateField.define<DecorationSet>({
  create: (state) => buildBlockDecorations(state),
  update(decorations, tr) {
    const relevant =
      tr.docChanged ||
      tr.selection !== undefined ||
      tr.effects.some((e) => e.is(setFocused) || e.is(setDiagramTheme) || e.is(setRevealSelection)) ||
      syntaxTree(tr.state) !== syntaxTree(tr.startState) ||
      tr.state.field(focusedField) !== tr.startState.field(focusedField)
    return relevant ? buildBlockDecorations(tr.state) : decorations
  },
  provide: (field) => EditorView.decorations.from(field),
})
