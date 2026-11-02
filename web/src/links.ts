import type { Extension } from "@codemirror/state"
import { EditorView } from "@codemirror/view"

/** Cmd+click follows links; plain clicks fall through to the editor so the caret can be placed. */
export function linkHandling(open: (href: string, newTab: boolean) => void): Extension {
  return EditorView.domEventHandlers({
    mousedown(event) {
      if (!event.metaKey || event.button !== 0) return false
      const target = (event.target as Element | null)?.closest?.("[data-href], a[href]")
      const href = target?.getAttribute("data-href") ?? target?.getAttribute("href")
      if (!href) return false
      event.preventDefault()
      open(href, event.shiftKey)
      return true
    },
    click(event) {
      if ((event.target as Element | null)?.closest?.("a[href]")) event.preventDefault()
      return false
    },
  })
}

export function trackCommandKey(): void {
  const update = (down: boolean) => document.body.classList.toggle("mdb-cmd", down)
  window.addEventListener("keydown", (e) => update(e.metaKey))
  window.addEventListener("keyup", (e) => update(e.metaKey))
  window.addEventListener("blur", () => update(false))
}
