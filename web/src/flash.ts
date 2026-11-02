import { StateEffect, StateField, type Extension } from "@codemirror/state"
import { Decoration, EditorView, type DecorationSet } from "@codemirror/view"

export const flashRange = StateEffect.define<{ from: number; to: number } | null>()

const flashMark = Decoration.mark({ class: "cm-md-flash" })

/** Temporary highlight used when jumping to a search result. */
export const flashField: Extension = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    value = value.map(tr.changes)
    for (const effect of tr.effects) {
      if (!effect.is(flashRange)) continue
      value =
        effect.value && effect.value.to > effect.value.from
          ? Decoration.set([flashMark.range(effect.value.from, effect.value.to)])
          : Decoration.none
    }
    return value
  },
  provide: (field) => EditorView.decorations.from(field),
})
