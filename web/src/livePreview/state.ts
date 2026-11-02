import { EditorState, StateEffect, StateField, type Extension } from "@codemirror/state"
import { EditorView } from "@codemirror/view"
import { currentDiagramTheme, type DiagramTheme } from "../render/mermaid"

export const setFocused = StateEffect.define<boolean>()

export const focusedField = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setFocused)) value = effect.value
    return value
  },
})

export const setDiagramTheme = StateEffect.define<DiagramTheme>()

/** Set while the find bar drives the selection, so matches show as source even without editor focus. */
export const setRevealSelection = StateEffect.define<boolean>()

export const revealSelectionField = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setRevealSelection)) value = effect.value
    return value
  },
})

export const diagramThemeField = StateField.define<DiagramTheme>({
  create: () => currentDiagramTheme(),
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setDiagramTheme)) value = effect.value
    return value
  },
})

export const editorStateTracking: Extension = [
  focusedField,
  diagramThemeField,
  revealSelectionField,
  EditorView.focusChangeEffect.of((_state, focusing) => setFocused.of(focusing)),
]

/** Source is revealed only where the caret is, and only while the editor has focus. */
export function selectionTouches(state: EditorState, from: number, to: number): boolean {
  if (!state.field(focusedField, false) && !state.field(revealSelectionField, false)) return false
  for (const range of state.selection.ranges) {
    if (range.from <= to && range.to >= from) return true
  }
  return false
}

export function linesTouch(state: EditorState, from: number, to: number): boolean {
  return selectionTouches(state, state.doc.lineAt(from).from, state.doc.lineAt(to).to)
}
