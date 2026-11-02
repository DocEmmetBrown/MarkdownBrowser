import { type EditorState } from "@codemirror/state"
import { EditorView } from "@codemirror/view"
import {
  SearchQuery,
  closeSearchPanel,
  getSearchQuery,
  openSearchPanel,
  replaceAll,
  replaceNext,
  search,
  searchPanelOpen,
  selectMatches,
  setSearchQuery,
} from "@codemirror/search"
import { setRevealSelection } from "./livePreview/state"

export interface FindOptions {
  search: string
  replace: string
  caseSensitive: boolean
  regexp: boolean
}

export interface FindStatus {
  current: number
  total: number
  valid: boolean
  wrapped: boolean
  atEnd: boolean
}

interface Match {
  from: number
  to: number
}

const maxCounted = 10_000

// The native find bar is the UI; CodeMirror's panel stays open but invisible because match highlighting needs it.
export const findPanel = search({
  top: true,
  createPanel: () => {
    const dom = document.createElement("div")
    dom.className = "cm-mdb-find-anchor"
    return { dom, top: true }
  },
})

function firstMatch(cursor: Iterator<Match>): Match | null {
  for (let r = cursor.next(); !r.done; r = cursor.next()) if (r.value.to > r.value.from) return r.value
  return null
}

function allMatches(state: EditorState, query: SearchQuery): Match[] {
  const matches: Match[] = []
  const cursor = query.getCursor(state)
  for (let r = cursor.next(); !r.done && matches.length < maxCounted; r = cursor.next()) {
    if (r.value.to > r.value.from) matches.push({ from: r.value.from, to: r.value.to })
  }
  return matches
}

export function findStatus(state: EditorState, flags = { wrapped: false, atEnd: false }): FindStatus {
  const query = getSearchQuery(state)
  if (!searchPanelOpen(state) || !query.search) return { current: 0, total: 0, valid: true, ...flags }
  if (!query.valid) return { current: 0, total: 0, valid: false, ...flags }
  const matches = allMatches(state, query)
  const { from, to } = state.selection.main
  return { current: matches.findIndex((m) => m.from === from && m.to === to) + 1, total: matches.length, valid: true, ...flags }
}

function select(view: EditorView, match: Match): void {
  view.dispatch({
    selection: { anchor: match.from, head: match.to },
    effects: [EditorView.scrollIntoView(match.from, { y: "center" }), setRevealSelection.of(true)],
    userEvent: "select.search",
  })
}

export function setFindQuery(view: EditorView, options: FindOptions): void {
  const query = new SearchQuery({
    search: options.search,
    replace: options.replace,
    caseSensitive: options.caseSensitive,
    regexp: options.regexp,
    literal: !options.regexp,
  })
  if (!searchPanelOpen(view.state)) openSearchPanel(view)
  view.dispatch({ effects: setSearchQuery.of(query) })
}

export function findNext(view: EditorView, wrap: boolean): FindStatus {
  const query = getSearchQuery(view.state)
  if (!query.valid || !query.search) return findStatus(view.state)
  let match = firstMatch(query.getCursor(view.state, view.state.selection.main.to))
  let wrapped = false
  if (!match) {
    if (!wrap) return findStatus(view.state, { wrapped: false, atEnd: true })
    match = firstMatch(query.getCursor(view.state))
    wrapped = match !== null
  }
  if (match) select(view, match)
  return findStatus(view.state, { wrapped, atEnd: false })
}

export function findPrevious(view: EditorView, wrap: boolean): FindStatus {
  const query = getSearchQuery(view.state)
  if (!query.valid || !query.search) return findStatus(view.state)
  const matches = allMatches(view.state, query)
  const from = view.state.selection.main.from
  let match = [...matches].reverse().find((m) => m.from < from) ?? null
  let wrapped = false
  if (!match) {
    if (!wrap) return findStatus(view.state, { wrapped: false, atEnd: true })
    match = matches[matches.length - 1] ?? null
    wrapped = match !== null
  }
  if (match) select(view, match)
  return findStatus(view.state, { wrapped, atEnd: false })
}

/** Replaces the selected match (selecting the first one if needed), then moves to the next. */
export function replaceCurrent(view: EditorView, wrap: boolean): FindStatus {
  const query = getSearchQuery(view.state)
  if (!query.valid || !query.search) return findStatus(view.state)
  const { from, to } = view.state.selection.main
  const isMatch = allMatches(view.state, query).some((m) => m.from === from && m.to === to)
  if (!isMatch) return findNext(view, wrap)
  const lengthBefore = view.state.doc.length
  replaceNext(view)
  const after = view.state.selection.main
  if (after.from < from && !wrap) {
    // CodeMirror always wraps to the next match; undo that when wrapping is off.
    view.dispatch({ selection: { anchor: to + view.state.doc.length - lengthBefore } })
    return findStatus(view.state, { wrapped: false, atEnd: true })
  }
  view.dispatch({ effects: setRevealSelection.of(true) })
  return findStatus(view.state, { wrapped: after.from < from, atEnd: false })
}

export function replaceAllMatches(view: EditorView): number {
  const query = getSearchQuery(view.state)
  if (!query.valid || !query.search) return 0
  const count = allMatches(view.state, query).length
  replaceAll(view)
  return count
}

export function selectAllMatches(view: EditorView): FindStatus {
  selectMatches(view)
  view.focus()
  return findStatus(view.state)
}

export function closeFind(view: EditorView): void {
  view.dispatch({ effects: setRevealSelection.of(false) })
  closeSearchPanel(view)
}
