// Security regression tests. These pin the invariants that keep attacker-controlled
// markdown inert inside the web view. They exist so dependency upgrades (rehype-sanitize,
// unified, katex, mermaid, …) cannot silently weaken rendering security: if an upgrade
// changes sanitizer behavior, these tests must fail loudly.
import { describe, expect, it, vi } from "vitest"
import { renderMarkdownHTML } from "../src/render/html"
import { renderMath } from "../src/render/math"
import { resolveResourceURL, type DocContext } from "../src/context"

vi.mock("mermaid", () => ({
  default: {
    initialize: vi.fn(),
    render: vi.fn(async () => ({ svg: "<svg><text>diagram</text></svg>" })),
  },
}))

const ctx: DocContext = {
  docId: 1,
  baseURL: "mdb-file://local/Users/me/docs/README.md",
  rootURL: "mdb-file://local/Users/me/",
}

function render(markdown: string): HTMLElement {
  const host = document.createElement("div")
  host.innerHTML = renderMarkdownHTML(markdown, ctx)
  return host
}

// Tags that must never survive sanitization, regardless of schema evolution.
const forbiddenTags = ["script", "iframe", "object", "embed", "form", "base", "meta", "link", "style"]
// Attributes whose values are URLs. `poster` is intentionally excluded: the current schema
// does not restrict its protocol, which is tolerated because engines fetch posters as images
// and never execute them (pinned separately below).
const urlAttributes = ["href", "src", "action", "formaction", "xlink:href", "background", "data-href", "srcset"]

function dangerousScheme(value: string): boolean {
  const compact = value.replace(/[\u0000-\u0020]+/g, "").toLowerCase()
  return /^(javascript|vbscript|data|file|blob):/.test(compact)
}

/** Asserts a rendered fragment is inert: no active content, no handler attributes, no DOM clobbering. */
function expectInert(host: HTMLElement): void {
  for (const tag of forbiddenTags) {
    expect(host.querySelector(tag), `unexpected <${tag}> in output`).toBeNull()
  }
  for (const el of host.querySelectorAll("*")) {
    for (const attr of el.attributes) {
      const name = attr.name.toLowerCase()
      // "open" (on <details>) is a legitimate attribute, not an event handler.
      expect(name.startsWith("on") && name !== "open", `${el.tagName} has handler attribute ${attr.name}`).toBe(false)
      if (urlAttributes.includes(name)) {
        expect(dangerousScheme(attr.value), `${el.tagName}[${attr.name}]="${attr.value}"`).toBe(false)
      }
    }
    // DOM clobbering defense: user-controlled ids/names must carry the GitHub prefix.
    const id = el.getAttribute("id")
    if (id !== null) expect(id.startsWith("user-content-"), `unprefixed id "${id}"`).toBe(true)
    const nameAttr = el.getAttribute("name")
    if (nameAttr !== null) expect(nameAttr.startsWith("user-content-"), `unprefixed name "${nameAttr}"`).toBe(true)
  }
}

const xssPayloads: Record<string, string> = {
  "img onerror": '<img src="x.png" onerror="alert(1)">',
  "script tag": "<script>alert(1)</script>",
  "markdown javascript: link": "[x](javascript:alert(1))",
  "raw javascript: link": '<a href="javascript:alert(1)">x</a>',
  "uppercase scheme": '<a href="JAVASCRIPT:alert(1)">x</a>',
  "tab-obfuscated scheme": '<a href="java\tscript:alert(1)">x</a>',
  "space-padded scheme": '<a href="  javascript:alert(1)">x</a>',
  "data: img": '<img src="data:text/html,<script>alert(1)</script>">',
  "data: base64 link": '<a href="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==">x</a>',
  "markdown data: link": "[x](data:text/html,<script>alert(1)</script>)",
  iframe: '<iframe src="https://evil.example"></iframe>',
  "iframe srcdoc": '<iframe srcdoc="<script>alert(1)</script>"></iframe>',
  form: '<form action="https://evil.example"><input type="text"></form>',
  "object and embed": '<object data="x.swf"></object><embed src="x">',
  "base hijack": '<base href="https://evil.example/">',
  "meta refresh": '<meta http-equiv="refresh" content="0;url=https://evil.example">',
  "mXSS mglyph/style": '<math><mtext><table><mglyph><style><!--</style><img title="--><img src=1 onerror=alert(1)>">',
  "svg script": '<svg><script>alert(1)</script><circle onload="alert(2)"/></svg>',
  "vbscript link": '<a href="vbscript:msgbox(1)">x</a>',
  "javascript: image": "![x](javascript:alert(1))",
  "srcset javascript:": '<img srcset="https://ok.example/x.png 1x, javascript:alert(1) 2x" src="x.png">',
  "file: link": '<a href="file:///etc/passwd">x</a>',
  "blob: img": '<img src="blob:https://evil.example/uuid">',
  "details ontoggle": '<details open ontoggle="alert(1)"><summary>s</summary>x</details>',
  "autofocus onfocus": '<input type="text" autofocus onfocus="alert(1)">',
  "style tag": "<style>body{background:url(https://evil.example)}</style>",
  "table background": '<table background="javascript:alert(1)"><tr><td>x</td></tr></table>',
  "id clobbering": '<a id="location" href="https://x.example">x</a>',
  "name clobbering": '<img name="document" src="x.png">',
  "heading name clobbering": '# <a name="getElementById">H</a>',
}

describe("markdown sanitization battery", () => {
  for (const [name, payload] of Object.entries(xssPayloads)) {
    it(`neutralizes ${name}`, () => {
      const host = render(payload)
      expectInert(host)
      // mXSS double-parse: re-serializing and re-parsing must not mutate into active content.
      const reparsed = document.createElement("div")
      reparsed.innerHTML = host.innerHTML
      expectInert(reparsed)
    })
  }

  it("strips the src attribute from a data: video source", () => {
    const video = render('<video src="data:text/html,x" controls></video>').querySelector("video")
    expect(video).not.toBeNull()
    expect(video!.hasAttribute("src")).toBe(false)
  })

  it("tolerates poster=\"javascript:\" as non-executable (pinned behavior)", () => {
    // The custom schema does not restrict poster's protocol. Engines only fetch posters
    // as images and never navigate to them, so this is inert — but if an upgrade changes
    // how poster is handled, this test forces a human to re-review the decision.
    const video = render('<video poster="javascript:alert(1)" src="v.mp4" controls></video>').querySelector("video")
    expect(video).not.toBeNull()
    expect(video!.getAttribute("src")).toMatch(/^mdb-file:/)
  })
})

describe("rendering pipeline order and URL rewriting", () => {
  it("keeps legitimate https links and copies them to data-href", () => {
    const a = render("[x](https://example.com/page)").querySelector("a")!
    expect(a.getAttribute("href")).toBe("https://example.com/page")
    expect(a.getAttribute("data-href")).toBe("https://example.com/page")
  })

  it("resolves relative img src against the document", () => {
    const img = render('<img src="img/a.png">').querySelector("img")!
    expect(img.getAttribute("src")).toBe("mdb-file://local/Users/me/docs/img/a.png")
  })

  it("resolves root-relative img src against the workspace root", () => {
    // This also pins that sanitization runs BEFORE URL rewriting: a rewritten
    // mdb-file: URL is not in the sanitizer's protocol allow-list, so the opposite
    // order would strip it.
    const img = render('<img src="/b.png">').querySelector("img")!
    expect(img.getAttribute("src")).toBe("mdb-file://local/Users/me/b.png")
  })

  it("upgrades protocol-relative URLs to https", () => {
    const img = render('<img src="//cdn.example/x.png">').querySelector("img")!
    expect(img.getAttribute("src")).toBe("https://cdn.example/x.png")
  })

  it("renders GFM tables, task lists, and details without handler attributes", () => {
    const host = render("| a |\n|---|\n| 1 |\n\n- [x] done\n\n<details open><summary>s</summary>x</details>")
    expect(host.querySelector("table")).not.toBeNull()
    expect(host.querySelector("input[disabled]")).not.toBeNull()
    expect(host.querySelector("details")).not.toBeNull()
    expectInert(host)
  })
})

describe("resolveResourceURL", () => {
  it("passes absolute URLs through unchanged", () => {
    expect(resolveResourceURL("https://example.com/x.png", ctx)).toBe("https://example.com/x.png")
    // Scheme passthrough is safe only because sanitization strips dangerous schemes
    // before this runs — the battery above pins that invariant.
    expect(resolveResourceURL("mailto:a@b.c", ctx)).toBe("mailto:a@b.c")
  })

  it("forces protocol-relative URLs to https", () => {
    expect(resolveResourceURL("//evil.example/x", ctx)).toBe("https://evil.example/x")
  })

  it("resolves relative and root-relative paths", () => {
    expect(resolveResourceURL("a/b.png", ctx)).toBe("mdb-file://local/Users/me/docs/a/b.png")
    expect(resolveResourceURL("/b.png", ctx)).toBe("mdb-file://local/Users/me/b.png")
  })

  it("falls back to the document base when there is no workspace root", () => {
    const noRoot: DocContext = { ...ctx, rootURL: null }
    expect(resolveResourceURL("/b.png", noRoot)).toBe("mdb-file://local/b.png")
  })
})

describe("KaTeX is untrusted", () => {
  const dangerousTex: Record<string, string> = {
    "\\href": "\\href{javascript:alert(1)}{click}",
    "\\includegraphics": "\\includegraphics{https://evil.example/x.png}",
    "\\htmlClass": "\\htmlClass{evil-class}{x}",
    "\\htmlId": "\\htmlId{evil-id}{x}",
    "\\htmlData": "\\htmlData{evil=yes}{x}",
  }

  for (const [command, tex] of Object.entries(dangerousTex)) {
    it(`refuses ${command}`, () => {
      const host = document.createElement("div")
      host.innerHTML = renderMath(tex, false)
      expect(host.querySelector("a[href]")).toBeNull()
      expect(host.querySelector("img")).toBeNull()
      expect(host.querySelector(".evil-class")).toBeNull()
      expect(host.querySelector("#evil-id")).toBeNull()
      expect(host.querySelector("[data-evil]")).toBeNull()
    })
  }

  it("renders valid math", () => {
    const host = document.createElement("div")
    host.innerHTML = renderMath("x^2", false)
    expect(host.querySelector(".katex")).not.toBeNull()
  })
})

describe("mermaid configuration", () => {
  async function mermaidMock() {
    return (await import("mermaid")).default as unknown as {
      initialize: ReturnType<typeof vi.fn>
      render: ReturnType<typeof vi.fn>
    }
  }

  it("always initializes with strict security before rendering", async () => {
    const { renderDiagram } = await import("../src/render/mermaid")
    await renderDiagram("graph TD; A-->B", "default")
    const mermaid = await mermaidMock()
    expect(mermaid.initialize).toHaveBeenCalledWith(
      expect.objectContaining({ securityLevel: "strict", startOnLoad: false }),
    )
    expect(mermaid.render).toHaveBeenCalledTimes(1)
  })

  it("serves repeated renders from the cache", async () => {
    const { renderDiagram } = await import("../src/render/mermaid")
    const mermaid = await mermaidMock()
    const before = mermaid.render.mock.calls.length
    expect(await renderDiagram("graph TD; A-->B", "default")).toContain("<svg>")
    expect(mermaid.render.mock.calls.length).toBe(before)
  })

  it("a failed render does not poison the queue", async () => {
    const { renderDiagram } = await import("../src/render/mermaid")
    const mermaid = await mermaidMock()
    mermaid.render.mockRejectedValueOnce(new Error("parse error"))
    await expect(renderDiagram("graph TD; broken", "default")).rejects.toThrow("parse error")
    await expect(renderDiagram("graph TD; C-->D", "default")).resolves.toContain("<svg>")
  })
})
