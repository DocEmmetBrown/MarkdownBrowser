import { commonmarkLanguage, markdown } from "@codemirror/lang-markdown"
import { languages } from "@codemirror/language-data"
import { GFM } from "@lezer/markdown"
import type { LanguageSupport } from "@codemirror/language"
import { MathSyntax } from "./math"

export function markdownSupport(): LanguageSupport {
  return markdown({
    base: commonmarkLanguage,
    extensions: [GFM, MathSyntax],
    codeLanguages: languages,
    addKeymap: true,
  })
}
