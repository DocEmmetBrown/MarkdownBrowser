import { describe, expect, it } from "vitest"
import { EditorState, Text } from "@codemirror/state"
import { EditorView } from "@codemirror/view"
import { SearchQuery, replaceAll, search, setSearchQuery } from "@codemirror/search"
import { find, matches, replace, validate, type EngineQuery } from "../src/search/engine"

const corpus = [
  "# Needle heading",
  "a needle, a NEEDLE and a nEEdle.",
  "café cafe\u0301 İstanbul 😀😀 a.b axb",
  "foo",
  "bar  ",
  "user@example other@host",
  "",
  "line with trailing tab\t",
].join("\n")

const cases: EngineQuery[] = [
  { search: "needle", caseSensitive: false, regexp: false },
  { search: "needle", caseSensitive: true, regexp: false },
  { search: "a.b", caseSensitive: false, regexp: false },
  { search: "i", caseSensitive: false, regexp: false },
  { search: "café", caseSensitive: false, regexp: false },
  { search: "n[e]+dle", caseSensitive: false, regexp: true },
  { search: "^#+ ", caseSensitive: true, regexp: true },
  { search: "foo\\nbar", caseSensitive: true, regexp: true },
  { search: "\\s+$", caseSensitive: true, regexp: true },
  { search: "😀+", caseSensitive: true, regexp: true },
  { search: "x*", caseSensitive: true, regexp: true },
  { search: "a.b", caseSensitive: true, regexp: true },
]

function codeMirrorMatches(doc: Text, q: EngineQuery): [number, number][] {
  const query = new SearchQuery({ ...q, literal: !q.regexp })
  const found: [number, number][] = []
  const cursor = query.getCursor(doc)
  for (let r = cursor.next(); !r.done; r = cursor.next()) if (r.value.to > r.value.from) found.push([r.value.from, r.value.to])
  return found
}

function codeMirrorReplaceAll(text: string, q: EngineQuery, replacement: string): string {
  const view = new EditorView({ state: EditorState.create({ doc: text, extensions: [search()] }) })
  view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ ...q, replace: replacement, literal: !q.regexp })) })
  replaceAll(view)
  const result = view.state.doc.toString()
  view.destroy()
  return result
}

describe("search engine", () => {
  it.each(cases)("finds what the find bar finds: $search", (q) => {
    const doc = Text.of(corpus.split("\n"))
    expect([...matches(doc, q)].map((m) => [m.from, m.to])).toEqual(codeMirrorMatches(doc, q))
  })

  it.each([
    [{ search: "(\\w+)@(\\w+)", caseSensitive: true, regexp: true }, "$2@$1"],
    [{ search: "needle", caseSensitive: false, regexp: true }, "[$&] $$ $9"],
    [{ search: "foo\\n", caseSensitive: true, regexp: true }, "joined\\t"],
    [{ search: "needle", caseSensitive: false, regexp: false }, "$1\\n"],
  ] as [EngineQuery, string][])("replaces like the find bar: %o -> %s", (q, replacement) => {
    expect(replace(corpus, "\n", q, replacement).text).toBe(codeMirrorReplaceAll(corpus, q, replacement))
  })

  it("reports lines and columns on the file's own line separator", () => {
    const text = "x\r\nab needle\r\nfoo\r\nbar\nbaz"
    const q = { search: "needle", caseSensitive: true, regexp: false }
    expect(find(text, "\r\n", q, 10)).toEqual([2, 3, 6])
    // A lone \n in a CRLF file stays inside its line, as in the editor; a match across a break counts it as one.
    expect(find(text, "\r\n", { search: "foo\\nbar", caseSensitive: true, regexp: true }, 10)).toEqual([3, 0, 7])
    expect(find(text, "\r\n", { search: "bar\\nbaz", caseSensitive: true, regexp: true }, 10)).toEqual([4, 0, 7])
  })

  it("stops at the limit", () => {
    expect(find("a a a a", "\n", { search: "a", caseSensitive: true, regexp: false }, 2)).toEqual([1, 0, 1, 1, 2, 1])
  })

  it("replaces across lines and keeps the separator", () => {
    const text = "one\r\ntwo\r\nthree\r\n"
    const q = { search: "one\\ntwo", caseSensitive: true, regexp: true }
    expect(replace(text, "\r\n", q, "1\\n2\\n")).toEqual({ text: "1\r\n2\r\n\r\nthree\r\n", count: 1 })
    expect(replace(text, "\r\n", { ...q, search: "two\\nthree" }, "[$&]").text).toBe("one\r\n[two\r\nthree]\r\n")
    expect(replace(text, "\r\n", { search: "zzz", caseSensitive: true, regexp: false }, "y")).toEqual({ text, count: 0 })
  })

  it("rejects invalid patterns with the JavaScript message", () => {
    expect(validate({ search: "(", caseSensitive: true, regexp: true })).toMatch(/regular expression/i)
    expect(validate({ search: "(", caseSensitive: true, regexp: false })).toBeNull()
    expect(find("(", "\n", { search: "(", caseSensitive: true, regexp: true }, 10)).toEqual([])
  })
})
