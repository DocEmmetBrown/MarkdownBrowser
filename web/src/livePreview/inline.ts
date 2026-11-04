import type { EditorState, Range } from "@codemirror/state"
import { Decoration, EditorView, ViewPlugin, type DecorationSet, type ViewUpdate } from "@codemirror/view"
import { syntaxTree } from "@codemirror/language"
import type { SyntaxNode, SyntaxNodeRef } from "@lezer/common"
import { blockKind, blockSpan, htmlBlockEnd } from "./blocks"
import { linesTouch, selectionTouches, setRevealSelection } from "./state"
import {
  AlertTitleWidget,
  BulletWidget,
  EmojiWidget,
  FootnoteLabelWidget,
  FootnoteRefWidget,
  ImageWidget,
  InlineMathWidget,
  TaskWidget,
} from "./widgets"
import { linkDefinitions, linkTarget } from "../markdownLinks"
import { footnoteAnchor, footnoteKey, footnotes, type Footnotes } from "../footnotes"
import { emojiFor } from "../syntax/emoji"

const hidden = Decoration.replace({})
const lineClasses = new Map<string, Decoration>()

function lineClass(cls: string): Decoration {
  let deco = lineClasses.get(cls)
  if (!deco) lineClasses.set(cls, (deco = Decoration.line({ class: cls })))
  return deco
}

const alertPattern = /^\s*>\s*\[!(note|tip|important|warning|caution)\]\s*$/i
const linkParents = new Set(["Link", "Image", "LinkReference", "Autolink"])

class Builder {
  readonly ranges: Range<Decoration>[] = []
  private readonly codeLines = new Set<number>()
  private readonly replacedLines = new Set<number>()
  private readonly definitions: Map<string, string>
  private readonly notes: Footnotes
  /** End of the last rendered block; nodes before it are hidden by the block widget. */
  private renderedTo = -1
  /** End of a merged HTML block shown as source, so its closing tag shows as source too. */
  private sourceTo = -1

  constructor(private readonly state: EditorState) {
    this.definitions = linkDefinitions(state)
    this.notes = footnotes(state)
  }

  build(from: number, to: number): void {
    syntaxTree(this.state).iterate({ from, to, enter: (node) => this.enter(node) })
    const doc = this.state.doc
    for (let pos = from; pos <= to; ) {
      const line = doc.lineAt(pos)
      if (!this.codeLines.has(line.number) && line.text.trim() === "") this.ranges.push(lineClass("cm-md-blank").range(line.from))
      pos = line.to + 1
    }
  }

  private hide(from: number, to: number): void {
    if (to > from) this.ranges.push(hidden.range(from, to))
  }

  private touches(from: number, to: number): boolean {
    return selectionTouches(this.state, from, to)
  }

  private lineActive(pos: number): boolean {
    const line = this.state.doc.lineAt(pos)
    return selectionTouches(this.state, line.from, line.to)
  }

  private href(node: SyntaxNode): string | null {
    return linkTarget(this.state, node, this.definitions)?.href ?? null
  }

  private enter(ref: SyntaxNodeRef): boolean | void {
    const { state } = this
    const doc = state.doc
    const node = ref.node
    const name = ref.name
    if (ref.from < this.renderedTo) return false

    const kind = blockKind(state, ref)
    if (kind) {
      const end = kind === "html" ? htmlBlockEnd(state, ref) : ref.to
      const span = blockSpan(state, ref.from, end)
      const asSource = (kind === "html" && ref.from < this.sourceTo) || linesTouch(state, span.lineFrom, span.lineTo)
      if (!asSource) {
        this.renderedTo = end
        return false
      }
      if (kind === "html") this.sourceTo = Math.max(this.sourceTo, end)
      if (kind !== "table") return this.codeBlock(node)
      return true
    }

    if (name.startsWith("ATXHeading")) {
      const line = doc.lineAt(ref.from)
      this.ranges.push(lineClass(`cm-md-h cm-md-h${name.slice(-1)}`).range(line.from))
      if (!this.lineActive(ref.from)) {
        for (const mark of node.getChildren("HeaderMark")) {
          if (mark.from === ref.from || doc.sliceString(line.from, mark.from).trim() === "") {
            let end = mark.to
            while (end < line.to && doc.sliceString(end, end + 1) === " ") end++
            this.hide(mark.from, end)
          } else {
            let start = mark.from
            while (start > line.from && doc.sliceString(start - 1, start) === " ") start--
            this.hide(start, mark.to)
          }
        }
      }
      return true
    }

    if (name.startsWith("SetextHeading")) {
      const level = name.slice(-1)
      const underline = node.getChild("HeaderMark")
      const first = doc.lineAt(ref.from).number
      const last = doc.lineAt(ref.to).number
      const active = linesTouch(state, ref.from, ref.to)
      for (let n = first; n <= last; n++) {
        const line = doc.line(n)
        if (underline && line.from <= underline.from && underline.from <= line.to) {
          if (!active) {
            this.ranges.push(lineClass("cm-md-collapsed").range(line.from))
            this.hide(line.from, line.to)
          }
        } else {
          this.ranges.push(lineClass(`cm-md-h cm-md-h${level}`).range(line.from))
        }
      }
      return true
    }

    switch (name) {
      case "Blockquote": {
        const first = doc.lineAt(ref.from)
        const last = doc.lineAt(ref.to)
        const alert = node.parent?.name === "Document" ? alertPattern.exec(first.text) : null
        const cls = alert ? `cm-md-quote cm-md-alert cm-md-alert-${alert[1].toLowerCase()}` : "cm-md-quote"
        for (let n = first.number; n <= last.number; n++) this.ranges.push(lineClass(cls).range(doc.line(n).from))
        if (alert && !this.lineActive(first.from)) {
          this.replacedLines.add(first.number)
          this.ranges.push(
            Decoration.replace({ widget: new AlertTitleWidget(alert[1].toLowerCase()) }).range(first.from, first.to),
          )
        }
        return true
      }
      case "QuoteMark": {
        const line = doc.lineAt(ref.from)
        if (this.replacedLines.has(line.number) || this.lineActive(ref.from)) return
        this.hide(ref.from, doc.sliceString(ref.to, ref.to + 1) === " " ? ref.to + 1 : ref.to)
        return
      }
      case "ListItem": {
        const line = doc.lineAt(ref.from)
        if (!this.replacedLines.has(line.number)) this.ranges.push(lineClass("cm-md-li").range(line.from))
        return true
      }
      case "ListMark": {
        if (this.lineActive(ref.from)) return
        const item = node.parent
        const list = item?.parent
        if (item?.getChild("Task")) {
          this.hide(ref.from, doc.sliceString(ref.to, ref.to + 1) === " " ? ref.to + 1 : ref.to)
        } else if (list?.name === "BulletList") {
          let depth = 0
          for (let p = list.parent; p; p = p.parent) if (p.name === "BulletList" || p.name === "OrderedList") depth++
          this.ranges.push(Decoration.replace({ widget: new BulletWidget(depth) }).range(ref.from, ref.to))
        } else {
          this.ranges.push(Decoration.mark({ class: "cm-md-ordered-mark" }).range(ref.from, ref.to))
        }
        return
      }
      case "TaskMarker": {
        if (this.touches(ref.from, ref.to)) return
        const checked = /x/i.test(doc.sliceString(ref.from, ref.to))
        this.ranges.push(Decoration.replace({ widget: new TaskWidget(checked) }).range(ref.from, ref.to))
        return
      }
      case "HorizontalRule": {
        if (this.lineActive(ref.from)) return
        this.ranges.push(lineClass("cm-md-hr").range(doc.lineAt(ref.from).from))
        this.hide(ref.from, ref.to)
        return
      }
      case "FencedCode":
      case "CodeBlock":
        return this.codeBlock(node)
      case "Emphasis":
      case "StrongEmphasis":
      case "Strikethrough": {
        if (!this.touches(ref.from, ref.to)) {
          for (const mark of node.getChildren(name === "Strikethrough" ? "StrikethroughMark" : "EmphasisMark")) {
            this.hide(mark.from, mark.to)
          }
        }
        return true
      }
      case "InlineCode": {
        this.ranges.push(Decoration.mark({ class: "cm-md-inline-code" }).range(ref.from, ref.to))
        if (!this.touches(ref.from, ref.to)) for (const mark of node.getChildren("CodeMark")) this.hide(mark.from, mark.to)
        return false
      }
      case "Link": {
        const target = linkTarget(state, node, this.definitions)
        if (!target) return true
        if (target.textTo > target.textFrom) {
          this.ranges.push(
            Decoration.mark({
              class: "cm-md-link",
              attributes: { "data-href": target.href, ...(target.title ? { title: target.title } : {}) },
            }).range(target.textFrom, target.textTo),
          )
        }
        if (!this.touches(ref.from, ref.to)) {
          this.hide(ref.from, target.textFrom)
          this.hide(target.textTo, ref.to)
        }
        return true
      }
      case "Image": {
        if (this.touches(ref.from, ref.to)) return true
        const target = linkTarget(state, node, this.definitions)
        if (!target) return true
        const parentHref = node.parent?.name === "Link" ? this.href(node.parent) : null
        const alt = doc.sliceString(target.textFrom, target.textTo)
        this.ranges.push(
          Decoration.replace({ widget: new ImageWidget(target.href, alt, target.title, parentHref) }).range(
            ref.from,
            ref.to,
          ),
        )
        return false
      }
      case "Autolink": {
        const url = node.getChild("URL")
        if (!url) return false
        const text = doc.sliceString(url.from, url.to)
        const href = /^[a-z][a-z0-9+.-]*:/i.test(text) ? text : text.includes("@") ? `mailto:${text}` : text
        this.ranges.push(Decoration.mark({ class: "cm-md-link", attributes: { "data-href": href } }).range(url.from, url.to))
        if (!this.touches(ref.from, ref.to)) {
          this.hide(ref.from, url.from)
          this.hide(url.to, ref.to)
        }
        return false
      }
      case "URL": {
        if (node.parent && linkParents.has(node.parent.name)) return false
        const text = doc.sliceString(ref.from, ref.to)
        const href = text.startsWith("www.") ? `http://${text}` : text.includes("@") && !text.includes(":") ? `mailto:${text}` : text
        this.ranges.push(Decoration.mark({ class: "cm-md-link", attributes: { "data-href": href } }).range(ref.from, ref.to))
        return false
      }
      case "InlineMath": {
        if (this.touches(ref.from, ref.to)) return false
        const tex = doc.sliceString(ref.from + 1, ref.to - 1)
        this.ranges.push(Decoration.replace({ widget: new InlineMathWidget(tex) }).range(ref.from, ref.to))
        return false
      }
      case "Escape": {
        if (!this.touches(ref.from, ref.to)) this.hide(ref.from, ref.from + 1)
        return false
      }
      case "HTMLTag":
      case "Comment": {
        this.ranges.push(Decoration.mark({ class: "cm-md-html" }).range(ref.from, ref.to))
        return false
      }
      case "LinkReference": {
        this.ranges.push(lineClass("cm-md-linkdef").range(doc.lineAt(ref.from).from))
        return false
      }
      case "FootnoteReference": {
        const label = node.getChild("FootnoteLabel")
        const key = label ? footnoteKey(doc.sliceString(label.from, label.to)) : ""
        const number = this.notes.numbers.get(key)
        if (number === undefined || this.touches(ref.from, ref.to)) return false
        this.ranges.push(
          Decoration.replace({ widget: new FootnoteRefWidget(number, footnoteAnchor(key)) }).range(ref.from, ref.to),
        )
        return false
      }
      case "FootnoteDefinition": {
        const last = doc.lineAt(ref.to).number
        for (let n = doc.lineAt(ref.from).number; n <= last; n++) {
          this.ranges.push(lineClass("cm-md-footnote").range(doc.line(n).from))
        }
        const mark = node.getChild("FootnoteDefinitionMark")
        const label = mark?.getChild("FootnoteLabel")
        const number = label ? this.notes.numbers.get(footnoteKey(doc.sliceString(label.from, label.to))) : undefined
        if (mark && number !== undefined && !this.lineActive(ref.from)) {
          const end = doc.sliceString(mark.to, mark.to + 1) === " " ? mark.to + 1 : mark.to
          this.ranges.push(Decoration.replace({ widget: new FootnoteLabelWidget(number) }).range(mark.from, end))
        }
        return true
      }
      case "FootnoteDefinitionMark":
        return false
      case "Emoji": {
        const emoji = emojiFor(doc.sliceString(ref.from + 1, ref.to - 1))
        if (emoji && !this.touches(ref.from, ref.to)) {
          this.ranges.push(Decoration.replace({ widget: new EmojiWidget(emoji) }).range(ref.from, ref.to))
        }
        return false
      }
    }
    return true
  }

  private codeBlock(node: SyntaxNode): false {
    const doc = this.state.doc
    const first = doc.lineAt(node.from)
    const last = doc.lineAt(node.to)
    const fenced = node.name === "FencedCode"
    const active = linesTouch(this.state, node.from, node.to)
    const closed = node.getChildren("CodeMark").length > 1
    for (let n = first.number; n <= last.number; n++) {
      this.codeLines.add(n)
      const line = doc.line(n)
      const isFence = fenced && !active && (n === first.number || (closed && n === last.number))
      let cls = "cm-md-code"
      if (n === first.number) cls += " cm-md-code-first"
      if (n === last.number) cls += " cm-md-code-last"
      if (isFence) cls += " cm-md-collapsed"
      this.ranges.push(lineClass(cls).range(line.from))
      if (isFence) this.hide(line.from, line.to)
    }
    return false
  }
}

function buildInlineDecorations(view: EditorView): DecorationSet {
  const builder = new Builder(view.state)
  builder.build(view.viewport.from, view.viewport.to)
  return Decoration.set(builder.ranges, true)
}

export const inlinePreview = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet

    constructor(view: EditorView) {
      this.decorations = buildInlineDecorations(view)
    }

    update(update: ViewUpdate) {
      if (
        update.docChanged ||
        update.viewportChanged ||
        update.selectionSet ||
        update.focusChanged ||
        update.transactions.some((tr) => tr.effects.some((e) => e.is(setRevealSelection))) ||
        syntaxTree(update.state) !== syntaxTree(update.startState)
      ) {
        this.decorations = buildInlineDecorations(update.view)
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
)
