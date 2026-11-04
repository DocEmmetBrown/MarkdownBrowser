import { beforeAll, describe, expect, it } from "vitest"
import type { EditorAPI } from "../src/editor"

const rich = [
  "# Title",
  "",
  "<details><summary>More</summary>hidden</details>",
  "",
  "Some **bold**, *em*, ~~gone~~, `code`, [link](other.md#part) and https://example.com.",
  "",
  "> [!NOTE]",
  "> Useful information.",
  "",
  "- [ ] open task",
  "- [x] done task",
  "  - nested",
  "",
  "1. first",
  "",
  "| a | b |",
  "|---|---|",
  "| 1 | 2 |",
  "",
  "![logo](img/logo.png)",
  "",
  "Inline $x^2$ math.",
  "",
  "$$",
  "e = mc^2",
  "$$",
  "",
  "```js",
  "const x = 1",
  "```",
  "",
  "```mermaid",
  "graph TD; A-->B",
  "```",
  "",
  "---",
  "",
  "Setext",
  "======",
  "",
].join("\n")

let api: EditorAPI

beforeAll(async () => {
  window.matchMedia = ((query: string) => ({
    matches: false,
    media: query,
    addEventListener() {},
    removeEventListener() {},
  })) as unknown as typeof window.matchMedia
  const { createEditor } = await import("../src/editor")
  const parent = document.createElement("div")
  document.body.appendChild(parent)
  api = createEditor(parent)
})

describe("live preview", () => {
  it("renders a rich document without throwing", () => {
    api.load({
      docId: 1,
      text: rich,
      lineSeparator: "\n",
      kind: "markdown",
      fileName: "README.md",
      baseURL: "mdb-file://local/tmp/README.md",
      rootURL: "mdb-file://local/tmp/",
      sourceMode: false,
    })
    const dom = api.view.dom
    expect(dom.querySelector(".cm-md-block-table table")).not.toBeNull()
    expect(dom.querySelector(".cm-md-link[data-href='other.md#part']")).not.toBeNull()
    expect(dom.querySelector("img.cm-md-image")?.getAttribute("src")).toBe("mdb-file://local/tmp/img/logo.png")
    expect(dom.querySelectorAll("input.cm-md-task").length).toBe(2)
    expect(dom.querySelector(".cm-md-alert-title-note")).not.toBeNull()
    expect(dom.querySelector(".cm-md-math-inline .katex")).not.toBeNull()
    expect(dom.querySelector(".cm-md-block-math .katex")).not.toBeNull()
    expect(dom.querySelector(".cm-md-block-html details")).not.toBeNull()
    expect(api.snapshot(1)?.text).toBe(rich)
  })

  it("toggles a task by changing exactly one character", () => {
    const box = api.view.dom.querySelector<HTMLInputElement>("input.cm-md-task")!
    box.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }))
    const text = api.snapshot(1)!.text
    expect(text).toBe(rich.replace("- [ ] open task", "- [x] open task"))
  })

  it("switches to source mode and back", () => {
    api.setSourceMode(true)
    expect(api.view.dom.classList.contains("cm-source")).toBe(true)
    expect(api.view.dom.querySelector(".cm-md-block-table")).toBeNull()
    api.setSourceMode(false)
    expect(api.view.dom.querySelector(".cm-md-block-table")).not.toBeNull()
  })

  it("marks clean after save and after external replace", () => {
    const snap = api.snapshot(1)!
    expect(snap.dirty).toBe(true)
    api.markSaved(1, snap.snapshotId)
    expect(api.snapshot(1)!.dirty).toBe(false)
    api.replaceText(1, snap.text + "tail\n")
    const after = api.snapshot(1)!
    expect(after.text.endsWith("tail\n")).toBe(true)
    expect(after.dirty).toBe(false)
  })

  it("wraps long lines unless turned off, for any kind of document", () => {
    const wraps = () => api.view.contentDOM.classList.contains("cm-lineWrapping")
    const base = { docId: 2, lineSeparator: "\n", baseURL: "mdb-file://local/tmp/a.txt", rootURL: null, sourceMode: false }
    api.load({ ...base, text: "x".repeat(500), kind: "text", fileName: "a.txt" })
    expect(wraps()).toBe(true)
    api.setLineWrapping(false)
    expect(wraps()).toBe(false)
    api.load({ ...base, text: "# a", kind: "markdown", fileName: "a.md", wrapLines: false })
    expect(wraps()).toBe(false)
    api.setLineWrapping(true)
    expect(wraps()).toBe(true)
  })
})
