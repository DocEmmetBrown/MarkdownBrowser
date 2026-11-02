// Pins the JS→native message contract: the web view may only send the shapes the Swift
// bridge handles. A dependency upgrade or refactor must not silently widen this channel.
import { afterEach, describe, expect, it, vi } from "vitest"
import { post, type OutMessage } from "../src/bridge"

type BridgeWindow = Window & { webkit?: { messageHandlers?: { bridge?: { postMessage(m: unknown): void } } } }

function installBridge(): unknown[] {
  const received: unknown[] = []
  ;(window as BridgeWindow).webkit = {
    messageHandlers: { bridge: { postMessage: (m: unknown) => received.push(m) } },
  }
  return received
}

afterEach(() => {
  delete (window as BridgeWindow).webkit
  vi.restoreAllMocks()
})

describe("bridge", () => {
  it("delivers each message type to the native handler unchanged", () => {
    const received = installBridge()
    const messages: OutMessage[] = [
      { type: "ready" },
      { type: "dirty", docId: 3, dirty: true },
      { type: "openLink", docId: 3, href: "https://example.com", newTab: false },
      { type: "findStatus", docId: 3, current: 1, total: 4, valid: true, wrapped: false, atEnd: false },
      { type: "error", message: "boom" },
    ]
    for (const message of messages) post(message)
    expect(received).toEqual(messages)
  })

  it("does not throw when the native handler is absent", () => {
    const debug = vi.spyOn(console, "debug").mockImplementation(() => {})
    expect(() => post({ type: "ready" })).not.toThrow()
    expect(debug).toHaveBeenCalledWith("[bridge]", { type: "ready" })
  })
})
