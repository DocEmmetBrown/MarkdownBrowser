import { Facet } from "@codemirror/state"

export interface DocContext {
  docId: number
  /** `mdb-file://` URL of the document itself; relative references resolve against it. */
  baseURL: string
  /** `mdb-file://` URL of the workspace folder (trailing slash), used for root-relative `/path` links. */
  rootURL: string | null
}

export const docContext = Facet.define<DocContext, DocContext>({
  combine: (values) => values[0] ?? { docId: 0, baseURL: "mdb-file://local/", rootURL: null },
})

const schemePattern = /^[a-z][a-z0-9+.-]*:/i

/** Resolve a URL found in markdown into something the web view can load. */
export function resolveResourceURL(src: string, ctx: DocContext): string {
  const trimmed = src.trim()
  if (schemePattern.test(trimmed)) return trimmed
  if (trimmed.startsWith("//")) return "https:" + trimmed
  try {
    if (trimmed.startsWith("/") && ctx.rootURL) return new URL(trimmed.slice(1), ctx.rootURL).href
    return new URL(trimmed, ctx.baseURL).href
  } catch {
    return trimmed
  }
}
