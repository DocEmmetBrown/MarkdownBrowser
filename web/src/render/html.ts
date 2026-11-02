import { unified } from "unified"
import remarkParse from "remark-parse"
import remarkGfm from "remark-gfm"
import remarkRehype from "remark-rehype"
import rehypeRaw from "rehype-raw"
import rehypeSanitize, { defaultSchema, type Options as SanitizeSchema } from "rehype-sanitize"
import rehypeStringify from "rehype-stringify"
import { visit } from "unist-util-visit"
import type { Element, Root } from "hast"
import { resolveResourceURL, type DocContext } from "../context"

// GitHub's own sanitizer allow-list, plus the media tags GitHub renders for attachments.
const schema: SanitizeSchema = {
  ...defaultSchema,
  tagNames: [...(defaultSchema.tagNames ?? []), "video", "source"],
  attributes: {
    ...defaultSchema.attributes,
    img: [...(defaultSchema.attributes?.img ?? []), "width", "height", "align"],
    video: ["src", "controls", "width", "height", "muted", "loop", "poster", "playsInline"],
    source: ["src", "type", "media"],
  },
}

const processor = unified()
  .use(remarkParse)
  .use(remarkGfm)
  .use(remarkRehype, { allowDangerousHtml: true })
  .use(rehypeRaw)
  .use(rehypeSanitize, schema)
  .use(rehypeStringify)
  .freeze()

const srcProperties: Record<string, string[]> = {
  img: ["src"],
  video: ["src", "poster"],
  source: ["src"],
}

function rewriteURLs(tree: Root, ctx: DocContext): void {
  visit(tree, "element", (node: Element) => {
    for (const property of srcProperties[node.tagName] ?? []) {
      const value = node.properties[property]
      if (typeof value === "string") node.properties[property] = resolveResourceURL(value, ctx)
    }
    if (node.tagName === "a" && typeof node.properties.href === "string") {
      node.properties.dataHref = node.properties.href
    }
  })
}

/** Render a markdown fragment the way GitHub would, with sanitized HTML and resolved local URLs. */
export function renderMarkdownHTML(markdown: string, ctx: DocContext): string {
  const tree = processor.runSync(processor.parse(markdown)) as Root
  rewriteURLs(tree, ctx)
  return processor.stringify(tree)
}
