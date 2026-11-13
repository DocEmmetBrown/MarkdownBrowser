// @vitest-environment node
// The JS search engine is the oracle for the native one: this records its results in goldens/search.json,
// which the native tests replay against the Rust engine. `npm run goldens` rewrites the file; otherwise the
// test fails when upstream (CodeMirror, V8) changes behavior, so the change can be ported.
import { describe, expect, it } from "vitest"
import { find, replace, validate, type EngineQuery } from "../src/search/engine"

const markdown = [
  "# Needle heading",
  "a needle, a NEEDLE and a nEEdle.",
  "café cafe\u0301 İstanbul 😀😀 a.b axb",
  "foo",
  "bar  ",
  "user@example other@host",
  "",
  "line with trailing tab\t",
  "- [ ] task with `code` and **bold** [link](https://example.com/a_b)",
  "$1 costs $$ and 100%",
]

// Longer than CodeMirror's 5000-character first chunk, so multi-line matches cross the chunk boundary.
const long = Array.from({ length: 400 }, (_, i) => `line ${i}: lorem ipsum ${i % 7 === 0 ? "needle" : "hay"}`)
long.push("marker")

const docs: { name: string; text: string; lineSeparator: string }[] = [
  { name: "markdown-lf", text: markdown.join("\n"), lineSeparator: "\n" },
  { name: "markdown-crlf", text: markdown.join("\r\n") + "\r\n", lineSeparator: "\r\n" },
  { name: "markdown-cr", text: markdown.join("\r"), lineSeparator: "\r" },
  { name: "crlf-with-lone-lf", text: "x\r\nab needle\r\nfoo\r\nbar\nbaz\r\nlone\rcr", lineSeparator: "\r\n" },
  {
    name: "unicode-case",
    text: "Straße STRASSE ß ẞ\nΣΑΣ σας ΌΣΟΣ\nİi ı I\nﬁle ﬀ Å Å K k\n½ ① ｆｕｌｌ ǅ",
    lineSeparator: "\n",
  },
  { name: "astral", text: "😀a😀 👍🏽 𝒜𝒷𝒸\n🇫🇷 a😀\n😀", lineSeparator: "\n" },
  { name: "blank-lines", text: "\n\na\n\n\nb\n", lineSeparator: "\n" },
  { name: "empty", text: "", lineSeparator: "\n" },
  { name: "long", text: long.join("\n"), lineSeparator: "\n" },
]

const literal = [
  "needle", "NEEDLE", "a.b", "i", "İ", "ı", "ss", "ß", "straße", "σ", "Σ", "ς", "fi", "ﬁ", "é", "e\u0301",
  "😀", "😀a", "\n", "foo\nbar", "$1", " ", "  ", "ipsum hay\nline", "k", "K", "½", "1⁄2", "full", "ǆ", "🇫",
]

const regexps = [
  "n[e]+dle", "^#+ ", "foo\\nbar", "\\s+$", "😀+", "x*", "a.b", "(\\w+)@(\\w+)", "(?<user>\\w+)@(?<host>\\w+)",
  "(?<=a )needle", "needle(?!,)", "\\bne", "\\p{Lu}+", "\\p{Script=Greek}+", "[^a-z\\s]+", "^$", "^", "$", ".",
  ".+", "\\d+", "[\\s\\S]{3}", "ß", "σ", "k", "\\u{1F600}", "\\x41", "\\cJ", "(a)|b", "(a)?b", "(.)\\1", "e\\u0301",
  "\\d+: lorem ipsum needle\\nline", ".*ipsum needle$", "[^]*?marker", "hay\\n(?=line 3)", "^line 9\\d:.*\\n.*$",
  "\\$\\d", "\\[.\\]", "\\*\\*\\w+\\*\\*", "(?:a|ab)(c|bcd)", "a{2,", "{", "\\-", "(", "[", "*", "a**", "\\k<x>",
  "(?i:x)", "\\p{Foo}", "[z-a]", "(?<n>a)(?<n>b)", "\\u{110000}", "(?<!\\d)\\d{2}(?!\\d)",
]

const regexpTemplates = ["$2@$1", "[$&] $$ $9 $10 $01 $0 $", "$<user>|\\n|\\t|\\\\n|\\r|\\x"]
const literalTemplates = ["[$&] $1\\n"]

function queries(): EngineQuery[] {
  const result: EngineQuery[] = []
  for (const caseSensitive of [true, false]) {
    for (const search of literal) result.push({ search, caseSensitive, regexp: false })
    for (const search of regexps) result.push({ search, caseSensitive, regexp: true })
  }
  return result
}

function record() {
  const cases = []
  for (const [index, doc] of docs.entries()) {
    for (const query of queries()) {
      const valid = validate(query) === null
      // The long document is there for find's chunking; its replaced texts would bloat the file.
      const long = doc.name === "long"
      const templates = long ? [] : query.regexp ? regexpTemplates : literalTemplates
      const replacements = templates.map((template) => {
        const result = replace(doc.text, doc.lineSeparator, query, template)
        return result.count > 0 ? { template, count: result.count, text: result.text } : { template, count: 0 }
      })
      cases.push({ doc: index, ...query, valid, find: find(doc.text, doc.lineSeparator, query, long ? 300 : 10_000), replacements })
    }
  }
  return { docs, cases }
}

function serialize(goldens: ReturnType<typeof record>): string {
  const docLines = goldens.docs.map((doc) => "    " + JSON.stringify(doc))
  const caseLines = goldens.cases.map((c) => "    " + JSON.stringify(c))
  return `{\n  "docs": [\n${docLines.join(",\n")}\n  ],\n  "cases": [\n${caseLines.join(",\n")}\n  ]\n}\n`
}

describe("search goldens", () => {
  it("match the JavaScript engine", async () => {
    await expect(serialize(record())).toMatchFileSnapshot("../../goldens/search.json")
  })
})
