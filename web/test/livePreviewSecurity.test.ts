// End-to-end security test: a hostile document loaded into the real editor must not
// produce active content anywhere in the editor DOM. Complements security.test.ts,
// which pins the renderers in isolation; this catches regressions in how widgets wire
// renderer output into the live preview.
import { beforeAll, describe, expect, it } from "vitest"
import type { EditorAPI } from "../src/editor"

const hostile = [
  "# <a name=\"location\">Title</a>",
  "",
  '<img src="x.png" onerror="alert(1)">',
  "",
  "<script>alert(1)</script>",
  "",
  "[click](javascript:alert(1)) and <a href=\"javascript:alert(2)\">raw</a>",
  "",
  "$\\href{javascript:alert(3)}{x}$",
  "",
  "$$",
  "\\includegraphics{https://evil.example/x.png}",
  "$$",
  "",
  '<iframe srcdoc="<script>alert(4)</script>"></iframe>',
  "",
  '<form action="https://evil.example"><input type="text"></form>',
  "",
  "```mermaid",
  'graph TD; A["<img src=x onerror=alert(5)>"]-->B',
  "```",
  "",
].join("\n")

let api: EditorAPI

beforeAll(async () => {
  const { createEditor } = await import("../src/editor")
  const parent = document.createElement("div")
  document.body.appendChild(parent)
  api = createEditor(parent)
})

describe("hostile document in the live preview", () => {
  it("produces no active content in the editor DOM", async () => {
    api.load({
      docId: 1,
      text: hostile,
      lineSeparator: "\n",
      kind: "markdown",
      fileName: "evil.md",
      baseURL: "mdb-file://local/tmp/evil.md",
      rootURL: "mdb-file://local/tmp/",
      sourceMode: false,
    })
    // Let async diagram rendering settle.
    await new Promise((resolve) => setTimeout(resolve, 50))

    const dom = api.view.dom
    for (const tag of ["script", "iframe", "object", "embed", "form", "base", "meta", "style"]) {
      expect(dom.querySelector(tag), `unexpected <${tag}>`).toBeNull()
    }
    for (const el of dom.querySelectorAll("*")) {
      for (const attr of el.attributes) {
        const name = attr.name.toLowerCase()
        expect(name.startsWith("on") && name !== "open", `${el.tagName} has handler ${attr.name}`).toBe(false)
        // data-href on preview spans is inert metadata (a span cannot navigate); the
        // native side enforces the scheme allow-list on cmd+click. On real anchors it
        // comes from sanitized HTML, so check it there.
        if (name === "href" || name === "src" || (name === "data-href" && el.tagName === "A")) {
          const compact = attr.value.replace(/[\u0000-\u0020]+/g, "").toLowerCase()
          expect(/^(javascript|vbscript|data|file|blob):/.test(compact), `${el.tagName}[${attr.name}]`).toBe(false)
        }
      }
      const id = el.getAttribute("id")
      if (id !== null && el.closest(".cm-md-block-html")) {
        expect(id.startsWith("user-content-"), `unprefixed id "${id}"`).toBe(true)
      }
    }
    // The document itself must remain byte-identical — sanitization must not corrupt the source.
    expect(api.snapshot(1)?.text).toBe(hostile)
  })
})
