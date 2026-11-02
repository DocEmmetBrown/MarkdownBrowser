import katex from "katex"

export function renderMath(tex: string, displayMode: boolean): string {
  return katex.renderToString(tex, { displayMode, throwOnError: false, trust: false, strict: "ignore" })
}
