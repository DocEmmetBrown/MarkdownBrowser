// Pins link-activation behavior: only cmd+click follows a link (delegating the target to
// the native side, which enforces the scheme allow-list), while plain clicks never
// navigate the web view.
import { describe, expect, it, vi } from "vitest"
import { EditorState } from "@codemirror/state"
import { EditorView } from "@codemirror/view"
import { linkHandling } from "../src/links"

function editorWithLink(): { view: EditorView; span: HTMLSpanElement; open: ReturnType<typeof vi.fn> } {
  const open = vi.fn()
  const view = new EditorView({
    state: EditorState.create({ doc: "x", extensions: [linkHandling(open)] }),
    parent: document.body,
  })
  const span = document.createElement("span")
  span.setAttribute("data-href", "guide.md#part")
  view.contentDOM.appendChild(span)
  return { view, span, open }
}

describe("link handling", () => {
  it("cmd+click opens the link target", () => {
    const { span, open } = editorWithLink()
    span.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, metaKey: true, button: 0 }))
    expect(open).toHaveBeenCalledWith("guide.md#part", false)
  })

  it("shift+cmd+click requests a new tab", () => {
    const { span, open } = editorWithLink()
    span.dispatchEvent(
      new MouseEvent("mousedown", { bubbles: true, cancelable: true, metaKey: true, shiftKey: true, button: 0 }),
    )
    expect(open).toHaveBeenCalledWith("guide.md#part", true)
  })

  it("plain mousedown does not open anything", () => {
    const { span, open } = editorWithLink()
    span.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 }))
    expect(open).not.toHaveBeenCalled()
  })

  it("right-click does not open anything", () => {
    const { span, open } = editorWithLink()
    span.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, metaKey: true, button: 2 }))
    expect(open).not.toHaveBeenCalled()
  })

  it("prevents default navigation when an anchor is clicked", () => {
    const { view } = editorWithLink()
    const anchor = document.createElement("a")
    anchor.setAttribute("href", "https://example.com")
    view.contentDOM.appendChild(anchor)
    const event = new MouseEvent("click", { bubbles: true, cancelable: true })
    anchor.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
  })

  it("ignores elements without a link target", () => {
    const { view, open } = editorWithLink()
    const plain = document.createElement("span")
    view.contentDOM.appendChild(plain)
    plain.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, metaKey: true, button: 0 }))
    expect(open).not.toHaveBeenCalled()
  })
})
