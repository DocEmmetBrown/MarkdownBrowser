export type OutMessage =
  | { type: "ready" }
  | { type: "dirty"; docId: number; dirty: boolean }
  | { type: "text"; docId: number; text: string }
  | { type: "openLink"; docId: number; href: string; newTab: boolean }
  | {
      type: "findStatus"
      docId: number
      current: number
      total: number
      valid: boolean
      wrapped: boolean
      atEnd: boolean
    }
  | { type: "error"; message: string }

interface WebKitBridge {
  postMessage(message: unknown): void
}

export function post(message: OutMessage): void {
  const handler = (window as unknown as { webkit?: { messageHandlers?: { bridge?: WebKitBridge } } }).webkit
    ?.messageHandlers?.bridge
  if (handler) handler.postMessage(message)
  else console.debug("[bridge]", message)
}
