import { describe, expect, it } from "vitest"
import { EditorState } from "@codemirror/state"
import { ensureSyntaxTree } from "@codemirror/language"
import { markdownSupport } from "../src/syntax"
import { minimalChange } from "../src/textDiff"
import { findAnchor } from "../src/anchors"
import { Slugger } from "../src/render/slug"
import { renderMarkdownHTML } from "../src/render/html"
import { linkDefinitions } from "../src/markdownLinks"

function stateFor(text: string, lineSeparator = "\n"): EditorState {
  const state = EditorState.create({
    doc: text,
    extensions: [EditorState.lineSeparator.of(lineSeparator), markdownSupport()],
  })
  ensureSyntaxTree(state, state.doc.length, 5000)
  return state
}

const samples = [
  "# Title\n\nSome *text* with `code`.\n",
  "line one\r\nline two\r\n\r\n- [ ] task\r\n",
  "no trailing newline",
  "mixed\r\nendings\nhere\r\n",
  "| a | b |\n|---|---|\n| 1 | 2 |\n\n```mermaid\ngraph TD; A-->B\n```\n",
  "\n\n\ttabs\t and  spaces  \n\n",
  "emoji 😀 and accents é e\u0301\n",
]

function separatorOf(text: string): string {
  return text.includes("\r\n") ? "\r\n" : "\n"
}

describe("byte-exact round trip", () => {
  for (const sample of samples) {
    it(JSON.stringify(sample.slice(0, 24)), () => {
      const state = stateFor(sample, separatorOf(sample))
      expect(state.sliceDoc()).toBe(sample)
    })
  }

  it("only changes what was typed", () => {
    const original = "# A\r\n\r\n* item\r\n* other\r\n"
    let state = stateFor(original, "\r\n")
    const pos = state.doc.line(3).to
    state = state.update({ changes: { from: pos, insert: "!" } }).state
    expect(state.sliceDoc()).toBe("# A\r\n\r\n* item!\r\n* other\r\n")
  })

  it("new lines use the file's separator", () => {
    let state = stateFor("a\r\nb\r\n", "\r\n")
    state = state.update({ changes: { from: 1, insert: state.lineBreak + "x" } }).state
    expect(state.sliceDoc()).toBe("a\r\nx\r\nb\r\n")
  })
})

describe("minimalChange", () => {
  it("finds the edited span", () => {
    const state = stateFor("hello world\n")
    const next = state.toText("hello brave world\n")
    expect(minimalChange(state.doc, next)).toEqual({ from: 6, to: 6, insertTo: 12 })
  })

  it("returns null when identical", () => {
    const state = stateFor("same")
    expect(minimalChange(state.doc, state.toText("same"))).toBeNull()
  })
})

describe("anchors", () => {
  it("slugs like GitHub, with duplicate suffixes", () => {
    const slugger = new Slugger()
    expect(slugger.slug("Hello, World!")).toBe("hello-world")
    expect(slugger.slug("Hello, World!")).toBe("hello-world-1")
    expect(slugger.slug("Café & Crème")).toBe("café--crème")
  })

  it("finds headings by fragment", () => {
    const state = stateFor("# Intro\n\ntext\n\n## Getting **Started**\n\nmore\n")
    expect(findAnchor(state, "getting-started")).toBe(state.doc.line(5).from)
    expect(findAnchor(state, "missing")).toBeNull()
  })
})

describe("link definitions", () => {
  it("collects reference definitions", () => {
    const state = stateFor("[Foo]: https://example.com\n\nSee [foo].\n")
    expect(linkDefinitions(state).get("foo")).toBe("https://example.com")
  })
})

describe("html rendering", () => {
  const ctx = { docId: 1, baseURL: "mdb-file://local/Users/me/docs/README.md", rootURL: "mdb-file://local/Users/me/" }

  it("sanitizes scripts and event handlers", () => {
    const html = renderMarkdownHTML('<img src="x.png" onerror="alert(1)"><script>alert(2)</script>', ctx)
    expect(html).not.toContain("onerror")
    expect(html).not.toContain("<script")
  })

  it("resolves relative and root-relative resources", () => {
    const html = renderMarkdownHTML('<img src="img/a.png"> <img src="/b.png">', ctx)
    expect(html).toContain('src="mdb-file://local/Users/me/docs/img/a.png"')
    expect(html).toContain('src="mdb-file://local/Users/me/b.png"')
  })

  it("renders GFM tables", () => {
    expect(renderMarkdownHTML("| a |\n|---|\n| 1 |\n", ctx)).toContain("<table>")
  })
})
