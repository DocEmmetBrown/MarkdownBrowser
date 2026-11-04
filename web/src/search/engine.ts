import { ChangeSet, Text, type ChangeSpec } from "@codemirror/state"
import { RegExpCursor, SearchCursor } from "@codemirror/search"

/**
 * Find and replace with exactly the find bar's semantics (CodeMirror's cursors, JavaScript regex),
 * shared by the editor and, through JavaScriptCore, by Find in Files.
 */
export interface EngineQuery {
  search: string
  caseSensitive: boolean
  regexp: boolean
}

interface EngineMatch {
  from: number
  to: number
  match: RegExpExecArray | null
}

// The flags CodeMirror's RegExpCursor compiles patterns with.
const regexpFlags = "gmu"

/** An error message for an invalid regular expression, or null. */
export function validate(query: EngineQuery): string | null {
  if (!query.regexp) return null
  try {
    new RegExp(query.search, regexpFlags)
    return null
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
}

/** Non-empty matches, as the find bar counts and highlights them. */
export function* matches(doc: Text, query: EngineQuery): Generator<EngineMatch> {
  if (!query.search || validate(query) !== null) return
  if (query.regexp) {
    const cursor = new RegExpCursor(doc, query.search, { ignoreCase: !query.caseSensitive })
    for (let r = cursor.next(); !r.done; r = cursor.next()) {
      if (r.value.to > r.value.from) yield { from: r.value.from, to: r.value.to, match: r.value.match }
    }
  } else {
    const normalize = query.caseSensitive ? undefined : (s: string) => s.toLowerCase()
    const cursor = new SearchCursor(doc, query.search, 0, doc.length, normalize)
    for (let r = cursor.next(); !r.done; r = cursor.next()) {
      if (r.value.to > r.value.from) yield { from: r.value.from, to: r.value.to, match: null }
    }
  }
}

// Outside literal mode CodeMirror turns \n, \r, \t and \\ in the replacement into the characters.
function unquote(text: string): string {
  return text.replace(/\\([nrt\\])/g, (_, ch: string) => (ch === "n" ? "\n" : ch === "r" ? "\r" : ch === "t" ? "\t" : "\\"))
}

/** The text a match is replaced with: `$&`, `$1`… and `$$` expand in regex mode, as in CodeMirror. */
export function replacementFor(query: EngineQuery, replace: string, match: RegExpExecArray | null): string {
  if (!query.regexp || !match) return replace
  return unquote(replace).replace(/\$([$&]|\d+)/g, (whole, ref: string) => {
    if (ref === "&") return match[0]
    if (ref === "$") return "$"
    for (let length = ref.length; length > 0; length--) {
      const group = +ref.slice(0, length)
      if (group > 0 && group < match.length) return (match[group] ?? "") + ref.slice(length)
    }
    return whole
  })
}

/** Line breaks in replacements (`\n`, or `$&` of a multi-line match) become the document's own separator. */
export function replacementChanges(doc: Text, query: EngineQuery, replace: string, lineSeparator = "\n"): ChangeSpec[] {
  const changes: ChangeSpec[] = []
  for (const m of matches(doc, query)) {
    const insert = replacementFor(query, replace, m.match)
    changes.push({ from: m.from, to: m.to, insert: lineSeparator === "\n" ? insert : insert.split("\n").join(lineSeparator) })
  }
  return changes
}

/** Matches in `text` split on `lineSeparator` (as the editor splits it), flattened to [line, column, length, …]. */
export function find(text: string, lineSeparator: string, query: EngineQuery, limit: number): number[] {
  const doc = Text.of(text.split(lineSeparator))
  const result: number[] = []
  for (const m of matches(doc, query)) {
    if (result.length >= limit * 3) break
    const line = doc.lineAt(m.from)
    result.push(line.number, m.from - line.from, m.to - m.from)
  }
  return result
}

export function replace(
  text: string,
  lineSeparator: string,
  query: EngineQuery,
  replacement: string,
): { text: string; count: number } {
  const doc = Text.of(text.split(lineSeparator))
  const changes = replacementChanges(doc, query, replacement, lineSeparator)
  if (changes.length === 0) return { text, count: 0 }
  const updated = ChangeSet.of(changes, doc.length, lineSeparator).apply(doc)
  return { text: updated.sliceString(0, updated.length, lineSeparator), count: changes.length }
}
