import type { EditorState } from "@codemirror/state"
import { syntaxTree } from "@codemirror/language"
import type { Tree } from "@lezer/common"
import { normalizeLabel } from "./markdownLinks"

export interface Footnotes {
  /** Numbers in order of first reference, for labels that have a definition (as GitHub numbers them). */
  numbers: Map<string, number>
  definitions: Map<string, number>
  firstReferences: Map<string, number>
}

const cache = new WeakMap<Tree, Footnotes>()
const candidate = /\[\^([^\]\s]+)\]/g

export function footnoteKey(label: string): string {
  return normalizeLabel(label)
}

export function footnoteAnchor(key: string): string {
  return `#user-content-fn-${encodeURIComponent(key)}`
}

export function footnotes(state: EditorState): Footnotes {
  const tree = syntaxTree(state)
  const cached = cache.get(tree)
  if (cached) return cached

  const definitions = new Map<string, number>()
  const references: [string, number][] = []
  // A text scan finds candidates cheaply; the tree confirms they aren't in code or link syntax.
  for (const match of state.doc.toString().matchAll(candidate)) {
    const node = tree.resolveInner(match.index + 2, 1)
    const owner = node.name === "FootnoteLabel" ? node.parent : null
    if (!owner) continue
    const key = footnoteKey(match[1])
    if (owner.name === "FootnoteReference") references.push([key, owner.from])
    else if (owner.name === "FootnoteDefinitionMark" && !definitions.has(key)) definitions.set(key, owner.from)
  }

  const numbers = new Map<string, number>()
  const firstReferences = new Map<string, number>()
  for (const [key, pos] of references) {
    if (!firstReferences.has(key)) firstReferences.set(key, pos)
    if (definitions.has(key) && !numbers.has(key)) numbers.set(key, numbers.size + 1)
  }
  const result = { numbers, definitions, firstReferences }
  cache.set(tree, result)
  return result
}
