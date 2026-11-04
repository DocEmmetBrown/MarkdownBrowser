import { afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { unsavedTextDelay, type EditorAPI, type LoadArgs } from "../src/editor"

type BridgeWindow = Window & { webkit?: { messageHandlers?: { bridge?: { postMessage(m: unknown): void } } } }

const received: { type: string; [key: string]: unknown }[] = []
let api: EditorAPI

const args = (overrides: Partial<LoadArgs>): LoadArgs => ({
  docId: 1,
  text: "saved\r\n",
  lineSeparator: "\r\n",
  kind: "markdown",
  fileName: "a.md",
  baseURL: "mdb-file://local/tmp/a.md",
  rootURL: null,
  sourceMode: false,
  ...overrides,
})

beforeAll(async () => {
  ;(window as BridgeWindow).webkit = {
    messageHandlers: { bridge: { postMessage: (m) => received.push(m as (typeof received)[number]) } },
  }
  const { createEditor } = await import("../src/editor")
  const parent = document.createElement("div")
  document.body.appendChild(parent)
  api = createEditor(parent)
})

afterEach(() => {
  vi.useRealTimers()
  received.length = 0
})

describe("unsaved text recovery", () => {
  it("copies unsaved text to Swift shortly after editing stops", () => {
    vi.useFakeTimers()
    api.load(args({}))
    expect(received).toEqual([{ type: "dirty", docId: 1, dirty: false }])
    api.view.dispatch({ changes: { from: 5, insert: "!" } })
    api.view.dispatch({ changes: { from: 6, insert: "?" } })
    vi.advanceTimersByTime(unsavedTextDelay - 1)
    expect(received.filter((m) => m.type === "text")).toEqual([])
    vi.advanceTimersByTime(1)
    expect(received.filter((m) => m.type === "text")).toEqual([{ type: "text", docId: 1, text: "saved!?\r\n" }])
  })

  it("doesn't copy text that was undone back to the saved version", () => {
    vi.useFakeTimers()
    api.load(args({}))
    api.view.dispatch({ changes: { from: 5, insert: "!" } })
    api.view.dispatch({ changes: { from: 5, to: 6 } })
    vi.advanceTimersByTime(unsavedTextDelay)
    expect(received.filter((m) => m.type === "text")).toEqual([])
  })

  it("restores recovered text as unsaved changes on load", () => {
    vi.useFakeTimers()
    api.load(args({ current: "saved\r\nrecovered\r\n" }))
    expect(received).toEqual([{ type: "dirty", docId: 1, dirty: true }])
    const snapshot = api.snapshot(1)!
    expect(snapshot.text).toBe("saved\r\nrecovered\r\n")
    expect(snapshot.dirty).toBe(true)

    // The saved version is still the baseline: removing the recovered line makes the document clean.
    const doc = api.view.state.doc
    api.view.dispatch({ changes: { from: doc.line(2).from, to: doc.line(3).from } })
    vi.advanceTimersByTime(150)
    expect(received.at(-1)).toEqual({ type: "dirty", docId: 1, dirty: false })
  })
})
