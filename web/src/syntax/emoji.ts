import type { InlineContext, MarkdownConfig } from "@lezer/markdown"
import { tags } from "@lezer/highlight"
import { nameToEmoji } from "gemoji"

const COLON = 58
// The same shortcodes remark-gemoji (and GitHub) recognise.
const shortcode = /^:(\+1|[-\w]+):/

export function emojiFor(name: string): string | undefined {
  return Object.hasOwn(nameToEmoji, name) ? nameToEmoji[name] : undefined
}

/** `:name:` shortcodes, only for names gemoji knows so `10:30:00` stays text. */
export const EmojiSyntax: MarkdownConfig = {
  defineNodes: [{ name: "Emoji", style: tags.character }],
  parseInline: [
    {
      name: "Emoji",
      parse(cx: InlineContext, next: number, pos: number): number {
        if (next !== COLON) return -1
        const match = shortcode.exec(cx.slice(pos, Math.min(cx.end, pos + 64)))
        if (!match || emojiFor(match[1]) === undefined) return -1
        return cx.addElement(cx.elt("Emoji", pos, pos + match[0].length))
      },
    },
  ],
}
