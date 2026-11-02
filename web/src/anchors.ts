import type { EditorState } from "@codemirror/state"
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language"
import { Slugger, headingPlainText } from "./render/slug"

const headingContainers = new Set(["Document", "Blockquote", "BulletList", "OrderedList", "ListItem"])

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

/** Document position for a URL fragment: a GitHub heading slug, or an explicit HTML id/name. */
export function findAnchor(state: EditorState, fragment: string): number | null {
  let target: string
  try {
    target = decodeURIComponent(fragment)
  } catch {
    target = fragment
  }
  target = target.replace(/^user-content-/, "")
  const lowered = target.toLowerCase()

  const tree = ensureSyntaxTree(state, state.doc.length, 500) ?? syntaxTree(state)
  const slugger = new Slugger()
  let found: number | null = null
  tree.iterate({
    enter(node) {
      if (found !== null) return false
      if (headingContainers.has(node.name)) return true
      if (/^(ATX|Setext)Heading/.test(node.name)) {
        let source = state.sliceDoc(node.from, node.to)
        if (node.name.startsWith("Setext")) source = source.split("\n")[0]
        if (slugger.slug(headingPlainText(source)) === lowered) found = node.from
      }
      return false
    },
  })
  if (found !== null) return found

  const explicit = new RegExp(`(?:id|name)\\s*=\\s*["']?${escapeRegExp(target)}["'\\s/>]`, "i")
  // doc.toString() joins with "\n", so match offsets equal document positions even for CRLF files.
  const match = explicit.exec(state.doc.toString())
  return match ? state.doc.lineAt(match.index).from : null
}
