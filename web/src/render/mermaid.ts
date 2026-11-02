import type { Mermaid } from "mermaid"

export type DiagramTheme = "default" | "dark"

let mermaidModule: Promise<Mermaid> | null = null
let configuredTheme: DiagramTheme | null = null
let renderQueue: Promise<unknown> = Promise.resolve()
let counter = 0
const cache = new Map<string, string>()
const maxCacheEntries = 64

export function currentDiagramTheme(): DiagramTheme {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default"
}

function cacheKey(code: string, theme: DiagramTheme): string {
  return theme + "\u0000" + code
}

export function cachedDiagram(code: string, theme: DiagramTheme): string | undefined {
  return cache.get(cacheKey(code, theme))
}

/** Renders a mermaid diagram to SVG markup. Renders are serialized because mermaid is not reentrant. */
export function renderDiagram(code: string, theme: DiagramTheme): Promise<string> {
  const key = cacheKey(code, theme)
  const cached = cache.get(key)
  if (cached !== undefined) return Promise.resolve(cached)

  const job = renderQueue.then(async () => {
    const mermaid = await (mermaidModule ??= import("mermaid").then((m) => m.default))
    if (configuredTheme !== theme) {
      mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme })
      configuredTheme = theme
    }
    const id = `mdb-mermaid-${++counter}`
    try {
      const { svg } = await mermaid.render(id, code)
      if (cache.size >= maxCacheEntries) cache.delete(cache.keys().next().value!)
      cache.set(key, svg)
      return svg
    } finally {
      document.getElementById(id)?.remove()
      document.getElementById("d" + id)?.remove()
    }
  })
  renderQueue = job.catch(() => undefined)
  return job
}
