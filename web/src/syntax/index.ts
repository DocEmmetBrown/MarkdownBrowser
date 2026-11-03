import { commonmarkLanguage, markdown } from "@codemirror/lang-markdown"
import { languages } from "@codemirror/language-data"
import { GFM } from "@lezer/markdown"
import type { LanguageSupport } from "@codemirror/language"
import { EmojiSyntax } from "./emoji"
import { FootnoteSyntax } from "./footnote"
import { MathSyntax } from "./math"

export function markdownSupport(): LanguageSupport {
  return markdown({
    base: commonmarkLanguage,
    extensions: [GFM, MathSyntax, FootnoteSyntax, EmojiSyntax],
    codeLanguages: languages,
    addKeymap: true,
  })
}
