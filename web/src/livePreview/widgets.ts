import { EditorView, WidgetType } from "@codemirror/view"
import { docContext, resolveResourceURL } from "../context"
import { renderMarkdownHTML } from "../render/html"
import { cachedDiagram, renderDiagram, type DiagramTheme } from "../render/mermaid"
import { renderMath } from "../render/math"

function remeasureOnLoad(root: HTMLElement, view: EditorView): void {
  for (const media of root.querySelectorAll("img, video")) {
    media.addEventListener("load", () => view.requestMeasure())
    media.addEventListener("loadedmetadata", () => view.requestMeasure())
  }
}

export class ImageWidget extends WidgetType {
  constructor(
    readonly src: string,
    readonly alt: string,
    readonly title: string | null,
    readonly href: string | null,
  ) {
    super()
  }

  eq(other: ImageWidget): boolean {
    return other.src === this.src && other.alt === this.alt && other.title === this.title && other.href === this.href
  }

  toDOM(view: EditorView): HTMLElement {
    const img = document.createElement("img")
    img.className = "cm-md-image"
    img.alt = this.alt
    if (this.title) img.title = this.title
    if (this.href) img.setAttribute("data-href", this.href)
    img.src = resolveResourceURL(this.src, view.state.facet(docContext))
    img.addEventListener("load", () => view.requestMeasure())
    return img
  }

  ignoreEvent(): boolean {
    return false
  }
}

export class BulletWidget extends WidgetType {
  constructor(readonly depth: number) {
    super()
  }

  eq(other: BulletWidget): boolean {
    return other.depth === this.depth
  }

  toDOM(): HTMLElement {
    const span = document.createElement("span")
    span.className = "cm-md-bullet"
    span.textContent = ["•", "◦", "▪"][this.depth % 3]
    return span
  }

  ignoreEvent(): boolean {
    return false
  }
}

export class TaskWidget extends WidgetType {
  constructor(readonly checked: boolean) {
    super()
  }

  eq(other: TaskWidget): boolean {
    return other.checked === this.checked
  }

  toDOM(view: EditorView): HTMLElement {
    const box = document.createElement("input")
    box.type = "checkbox"
    box.className = "cm-md-task"
    box.checked = this.checked
    box.addEventListener("mousedown", (event) => {
      event.preventDefault()
      const pos = view.posAtDOM(box)
      const marker = view.state.sliceDoc(pos, pos + 3)
      if (!/^\[[ xX]\]$/.test(marker)) return
      view.dispatch({ changes: { from: pos + 1, to: pos + 2, insert: marker[1] === " " ? "x" : " " } })
    })
    return box
  }

  ignoreEvent(): boolean {
    return true
  }
}

const alertTitles: Record<string, string> = {
  note: "Note",
  tip: "Tip",
  important: "Important",
  warning: "Warning",
  caution: "Caution",
}

export class AlertTitleWidget extends WidgetType {
  constructor(readonly kind: string) {
    super()
  }

  eq(other: AlertTitleWidget): boolean {
    return other.kind === this.kind
  }

  toDOM(): HTMLElement {
    const span = document.createElement("span")
    span.className = `cm-md-alert-title cm-md-alert-title-${this.kind}`
    span.textContent = alertTitles[this.kind] ?? this.kind
    return span
  }

  ignoreEvent(): boolean {
    return false
  }
}

export class InlineMathWidget extends WidgetType {
  constructor(readonly tex: string) {
    super()
  }

  eq(other: InlineMathWidget): boolean {
    return other.tex === this.tex
  }

  toDOM(): HTMLElement {
    const span = document.createElement("span")
    span.className = "cm-md-math-inline"
    span.innerHTML = renderMath(this.tex, false)
    return span
  }

  ignoreEvent(): boolean {
    return false
  }
}

export type BlockKind = "table" | "html" | "mermaid" | "math"

/** Rendered replacement (or live preview) for a multi-line markdown construct. */
export class BlockWidget extends WidgetType {
  constructor(
    readonly kind: BlockKind,
    readonly source: string,
    readonly theme: DiagramTheme,
    readonly isPreview: boolean,
  ) {
    super()
  }

  eq(other: BlockWidget): boolean {
    return (
      other.kind === this.kind &&
      other.source === this.source &&
      other.isPreview === this.isPreview &&
      (this.kind !== "mermaid" || other.theme === this.theme)
    )
  }

  get estimatedHeight(): number {
    return this.kind === "mermaid" ? 240 : 60
  }

  toDOM(view: EditorView): HTMLElement {
    const div = document.createElement("div")
    div.className = `cm-md-block cm-md-block-${this.kind}${this.isPreview ? " cm-md-block-preview" : ""}`
    switch (this.kind) {
      case "table":
      case "html":
        div.innerHTML = renderMarkdownHTML(this.source, view.state.facet(docContext))
        remeasureOnLoad(div, view)
        break
      case "math":
        div.innerHTML = renderMath(this.source, true)
        break
      case "mermaid":
        this.renderDiagram(div, view)
        break
    }
    return div
  }

  private renderDiagram(div: HTMLElement, view: EditorView): void {
    const cached = cachedDiagram(this.source, this.theme)
    if (cached !== undefined) {
      div.innerHTML = cached
      return
    }
    div.classList.add("cm-md-loading")
    renderDiagram(this.source, this.theme)
      .then((svg) => {
        div.innerHTML = svg
      })
      .catch((error: unknown) => {
        const pre = document.createElement("pre")
        pre.className = "cm-md-error"
        pre.textContent = error instanceof Error ? error.message : String(error)
        div.replaceChildren(pre)
      })
      .finally(() => {
        div.classList.remove("cm-md-loading")
        view.requestMeasure()
      })
  }

  ignoreEvent(): boolean {
    return false
  }
}
