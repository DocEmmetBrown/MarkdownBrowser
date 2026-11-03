// @vitest-environment node
// Find in Files runs the engine in JavaScriptCore, which has no DOM.
import { describe, expect, it } from "vitest"

describe("search engine without a DOM", () => {
  it("loads and searches", async () => {
    expect(typeof (globalThis as { document?: unknown }).document).toBe("undefined")
    const engine = await import("../src/search/bundle")
    expect(engine.find("a\nb a", "\n", { search: "A", caseSensitive: false, regexp: false }, 10)).toEqual([1, 0, 1, 2, 2, 1])
  })
})
