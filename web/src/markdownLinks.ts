import type { EditorState } from "@codemirror/state"
import { syntaxTree } from "@codemirror/language"
import type { SyntaxNode } from "@lezer/common"

const definitionContainers = new Set(["Document", "Blockquote", "BulletList", "OrderedList", "ListItem"])

export function normalizeLabel(label: string): string {
  return label.replace(/^\[|\]$/g, "").trim().replace(/\s+/g, " ").toLowerCase()
}

function stripAngleBrackets(url: string): string {
  return url.startsWith("<") && url.endsWith(">") ? url.slice(1, -1) : url
}

/** Collects `[label]: url` reference definitions. */
export function linkDefinitions(state: EditorState): Map<string, string> {
  const definitions = new Map<string, string>()
  syntaxTree(state).iterate({
    enter(node) {
      if (definitionContainers.has(node.name)) return true
      if (node.name === "LinkReference") {
        const label = node.node.getChild("LinkLabel")
        const url = node.node.getChild("URL")
        if (label && url) {
          const key = normalizeLabel(state.sliceDoc(label.from, label.to))
          if (!definitions.has(key)) definitions.set(key, stripAngleBrackets(state.sliceDoc(url.from, url.to)))
        }
      }
      return false
    },
  })
  return definitions
}

/** Text range and destination of a `Link` or `Image` node, or null when it isn't actually a link. */
export function linkTarget(
  state: EditorState,
  node: SyntaxNode,
  definitions: Map<string, string>,
): { textFrom: number; textTo: number; href: string; title: string | null } | null {
  const marks = node.getChildren("LinkMark")
  if (marks.length < 2) return null
  const textFrom = marks[0].to
  const textTo = marks[1].from
  const url = node.getChild("URL")
  const titleNode = node.getChild("LinkTitle")
  const title = titleNode ? state.sliceDoc(titleNode.from + 1, titleNode.to - 1) : null
  if (url) return { textFrom, textTo, href: stripAngleBrackets(state.sliceDoc(url.from, url.to)), title }
  const label = node.getChild("LinkLabel")
  let key = label ? normalizeLabel(state.sliceDoc(label.from, label.to)) : ""
  if (key === "") key = normalizeLabel(state.sliceDoc(textFrom, textTo))
  if (key === "") return null
  const href = definitions.get(key)
  return href === undefined ? null : { textFrom, textTo, href, title }
}
