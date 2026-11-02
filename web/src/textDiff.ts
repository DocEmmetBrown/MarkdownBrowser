import type { Text } from "@codemirror/state"

/** Smallest single replacement turning `before` into `after`, in document positions. */
export function minimalChange(before: Text, after: Text): { from: number; to: number; insertTo: number } | null {
  const a = before.toString()
  const b = after.toString()
  if (a === b) return null
  let start = 0
  const max = Math.min(a.length, b.length)
  while (start < max && a.charCodeAt(start) === b.charCodeAt(start)) start++
  let endA = a.length
  let endB = b.length
  while (endA > start && endB > start && a.charCodeAt(endA - 1) === b.charCodeAt(endB - 1)) {
    endA--
    endB--
  }
  return { from: start, to: endA, insertTo: endB }
}
