import { beforeAll, describe, expect, it } from "vitest"
import type { EditorAPI } from "../src/editor"
import { findAnchor } from "../src/anchors"
import { setFocused } from "../src/livePreview/state"
import { renderMarkdownHTML } from "../src/render/html"

const source = [
  "A note[^b], another[^a] and again[^b]. Missing[^none] :smile: :+1: at 10:30:00 :notanemoji:",
  "",
  "<details>",
  "<summary>More</summary>",
  "",
  "Hidden **bold** body.",
  "",
  "</details>",
  "",
  "`[^a] :smile:` in code",
  "",
  "[^a]: First *note*.",
  "[^b]: Second note",
  "    continued.",
  "",
].join("\n")

let api: EditorAPI

beforeAll(async () => {
  const { createEditor } = await import("../src/editor")
  const parent = document.createElement("div")
  document.body.appendChild(parent)
  api = createEditor(parent)
  api.load({
    docId: 1,
    text: source,
    lineSeparator: "\n",
    kind: "markdown",
    fileName: "notes.md",
    baseURL: "mdb-file://local/tmp/notes.md",
    rootURL: null,
    sourceMode: false,
  })
})

const texts = (selector: string) => [...api.view.dom.querySelectorAll(selector)].map((el) => el.textContent)

describe("footnotes", () => {
  it("numbers references by first use, only when defined", () => {
    expect(texts(".cm-md-footnote-ref")).toEqual(["1", "2", "1"])
    expect(api.view.dom.querySelector(".cm-md-footnote-ref")?.getAttribute("data-href")).toBe("#user-content-fn-b")
    expect(api.view.dom.textContent).toContain("Missing[^none]")
    expect(texts(".cm-md-footnote-label")).toEqual(["2.", "1."])
    expect(api.view.dom.querySelectorAll(".cm-line.cm-md-footnote").length).toBe(3)
    expect(api.snapshot(1)?.text).toBe(source)
  })

  it("resolves GitHub footnote anchors", () => {
    const state = api.view.state
    expect(findAnchor(state, "user-content-fn-a")).toBe(source.indexOf("[^a]:"))
    expect(findAnchor(state, "fnref-a")).toBe(source.indexOf("[^a]"))
    expect(findAnchor(state, "fn-none")).toBeNull()
  })
})

describe("emoji shortcodes", () => {
  it("renders known names outside code", () => {
    expect(texts(".cm-md-emoji")).toEqual(["😄", "👍"])
    expect(api.view.dom.textContent).toContain("10:30:00 :notanemoji:")
  })

  it("renders inside HTML fragments", () => {
    const ctx = { docId: 1, baseURL: "mdb-file://local/tmp/a.md", rootURL: null }
    expect(renderMarkdownHTML("| a |\n|---|\n| :tada: |", ctx)).toContain("🎉")
  })
})

describe("HTML blocks split by blank lines", () => {
  it("renders a details element with its Markdown body as one block", () => {
    const blocks = api.view.dom.querySelectorAll(".cm-md-block-html")
    expect(blocks.length).toBe(1)
    expect(blocks[0].querySelector("details > summary")?.textContent).toBe("More")
    expect(blocks[0].querySelector("details strong")?.textContent).toBe("bold")
  })

  it("shows the whole block as source while the caret is inside", () => {
    api.view.dispatch({ selection: { anchor: source.indexOf("<summary>") }, effects: setFocused.of(true) })
    expect(api.view.dom.querySelector(".cm-md-block-html")).toBeNull()
    expect(api.view.dom.textContent).toContain("</details>")
    api.view.dispatch({ effects: setFocused.of(false) })
    expect(api.view.dom.querySelectorAll(".cm-md-block-html").length).toBe(1)
  })
})
