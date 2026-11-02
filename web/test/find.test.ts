import { describe, expect, it } from "vitest"
import { EditorState } from "@codemirror/state"
import { EditorView } from "@codemirror/view"
import {
  findNext,
  findPanel,
  findPrevious,
  findStatus,
  replaceAllMatches,
  replaceCurrent,
  setFindQuery,
  type FindOptions,
} from "../src/find"
import { editorStateTracking } from "../src/livePreview/state"

function editor(text: string, options: Partial<FindOptions>): EditorView {
  const view = new EditorView({
    parent: document.body,
    state: EditorState.create({ doc: text, extensions: [findPanel, editorStateTracking] }),
  })
  setFindQuery(view, { search: "", replace: "", caseSensitive: false, regexp: false, ...options })
  return view
}

describe("find", () => {
  it("counts matches respecting case sensitivity", () => {
    expect(findStatus(editor("Foo foo FOO", { search: "foo" }).state).total).toBe(3)
    expect(findStatus(editor("Foo foo FOO", { search: "foo", caseSensitive: true }).state).total).toBe(1)
  })

  it("treats non-regex queries literally", () => {
    expect(findStatus(editor("a.b axb a\\nb", { search: "a.b" }).state).total).toBe(1)
    expect(findStatus(editor("a.b axb", { search: "a.b", regexp: true }).state).total).toBe(2)
  })

  it("reports invalid regular expressions", () => {
    expect(findStatus(editor("x", { search: "(", regexp: true }).state).valid).toBe(false)
  })

  it("wraps around only when enabled", () => {
    const view = editor("one two one", { search: "one" })
    expect(findNext(view, true).current).toBe(1)
    expect(findNext(view, true).current).toBe(2)
    const wrapped = findNext(view, true)
    expect(wrapped).toMatchObject({ current: 1, wrapped: true })

    findNext(view, false)
    expect(findNext(view, false)).toMatchObject({ current: 2, atEnd: true })
    expect(findPrevious(view, false).current).toBe(1)
    expect(findPrevious(view, false)).toMatchObject({ current: 1, atEnd: true })
    expect(findPrevious(view, true)).toMatchObject({ current: 2, wrapped: true })
  })

  it("replaces the current match then moves on", () => {
    const view = editor("cat cat cat", { search: "cat", replace: "dog" })
    replaceCurrent(view, true) // selects the first match
    replaceCurrent(view, true)
    expect(view.state.doc.toString()).toBe("dog cat cat")
    expect(findStatus(view.state).current).toBe(1)
  })

  it("does not wrap after the last replacement when wrapping is off", () => {
    const view = editor("cat x cat", { search: "cat", replace: "dog" })
    findNext(view, false)
    findNext(view, false)
    const status = replaceCurrent(view, false)
    expect(view.state.doc.toString()).toBe("cat x dog")
    expect(status.atEnd).toBe(true)
    expect(view.state.selection.main.head).toBe(9)
  })

  it("replaces all with regex groups", () => {
    const view = editor("a1 b2 c3", { search: "([a-z])(\\d)", replace: "$2$1", regexp: true })
    expect(replaceAllMatches(view)).toBe(3)
    expect(view.state.doc.toString()).toBe("1a 2b 3c")
  })
})
