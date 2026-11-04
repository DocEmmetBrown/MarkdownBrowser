import { Compartment, EditorState, Text, type Extension } from "@codemirror/state"
import {
  EditorView,
  drawSelection,
  dropCursor,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from "@codemirror/view"
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands"
import { HighlightStyle, LanguageDescription, syntaxHighlighting } from "@codemirror/language"
import { languages } from "@codemirror/language-data"
import { searchPanelOpen } from "@codemirror/search"
import { classHighlighter, tags } from "@lezer/highlight"
import { post } from "./bridge"
import { docContext } from "./context"
import { findAnchor } from "./anchors"
import {
  closeFind,
  findNext,
  findPanel,
  findPrevious,
  findStatus,
  replaceAllMatches,
  replaceCurrent,
  selectAllMatches,
  setFindQuery,
  type FindOptions,
  type FindStatus,
} from "./find"
import { flashField, flashRange } from "./flash"
import { linkHandling, trackCommandKey } from "./links"
import { blockPreviewField } from "./livePreview/blocks"
import { inlinePreview } from "./livePreview/inline"
import { editorStateTracking, setDiagramTheme } from "./livePreview/state"
import { currentDiagramTheme } from "./render/mermaid"
import { markdownSupport } from "./syntax"
import { minimalChange } from "./textDiff"

export type DocumentKind = "markdown" | "text"

export interface LoadArgs {
  docId: number
  text: string
  lineSeparator: string
  kind: DocumentKind
  fileName: string
  baseURL: string
  rootURL: string | null
  sourceMode: boolean
  anchor?: string | null
  /** Unsaved text to show instead of `text` (the saved version), e.g. after the web process restarted. */
  current?: string | null
}

export interface Snapshot {
  snapshotId: number
  text: string
  dirty: boolean
}

const extraHighlighting = HighlightStyle.define([{ tag: tags.strikethrough, textDecoration: "line-through" }])

/** How long after the last edit the unsaved text is copied to Swift, which restores it if this process dies. */
export const unsavedTextDelay = 1000

// Cmd+[ / Cmd+] are the app's Back/Forward shortcuts; find shortcuts belong to the native find bar.
const editorKeymap = defaultKeymap.filter((binding) => binding.key !== "Mod-[" && binding.key !== "Mod-]")

export function createEditor(parent: HTMLElement) {
  let docId = 0
  let kind: DocumentKind = "markdown"
  let sourceMode = false
  let savedDoc: Text = Text.empty
  let reportedDirty = false
  let applyingExternalChange = false
  let dirtyCheck: ReturnType<typeof setTimeout> | undefined
  let unsavedTextUpdate: ReturnType<typeof setTimeout> | undefined
  let findStatusUpdate: ReturnType<typeof setTimeout> | undefined
  let snapshotCounter = 0
  const snapshots = new Map<number, Text>()

  const mode = new Compartment()
  const language = new Compartment()
  const wrapping = new Compartment()

  function modeExtensions(): Extension {
    if (kind === "markdown" && !sourceMode) {
      return [blockPreviewField, inlinePreview, EditorView.editorAttributes.of({ class: "cm-live" })]
    }
    return [lineNumbers(), highlightActiveLineGutter(), EditorView.editorAttributes.of({ class: "cm-source" })]
  }

  function setDirty(dirty: boolean): void {
    if (dirty === reportedDirty) return
    reportedDirty = dirty
    post({ type: "dirty", docId, dirty })
  }

  // Becoming dirty is reported synchronously so autosave never misses an edit; the
  // (O(n)) check for edits that were undone back to the saved text is debounced.
  function documentChanged(): void {
    setDirty(true)
    clearTimeout(dirtyCheck)
    dirtyCheck = setTimeout(() => setDirty(!view.state.doc.eq(savedDoc)), 150)
    clearTimeout(unsavedTextUpdate)
    unsavedTextUpdate = setTimeout(() => {
      if (!view.state.doc.eq(savedDoc)) post({ type: "text", docId, text: view.state.sliceDoc() })
    }, unsavedTextDelay)
  }

  function openLink(href: string, newTab: boolean): void {
    if (href.startsWith("#")) scrollToAnchor(href.slice(1))
    else post({ type: "openLink", docId, href, newTab })
  }

  function reportFind(status: FindStatus = findStatus(view.state)): void {
    clearTimeout(findStatusUpdate)
    post({ type: "findStatus", docId, ...status })
  }

  function commonExtensions(args: LoadArgs): Extension {
    return [
      EditorState.lineSeparator.of(args.lineSeparator),
      docContext.of({ docId: args.docId, baseURL: args.baseURL, rootURL: args.rootURL }),
      editorStateTracking,
      flashField,
      history(),
      drawSelection(),
      dropCursor(),
      findPanel,
      keymap.of([...editorKeymap, ...historyKeymap, indentWithTab]),
      syntaxHighlighting(classHighlighter),
      syntaxHighlighting(extraHighlighting),
      linkHandling(openLink),
      EditorView.updateListener.of((update) => {
        if (update.docChanged && !applyingExternalChange) documentChanged()
        if (update.docChanged && searchPanelOpen(update.state)) {
          clearTimeout(findStatusUpdate)
          findStatusUpdate = setTimeout(() => reportFind(), 150)
        }
      }),
      wrapping.of(args.kind === "markdown" ? EditorView.lineWrapping : []),
      language.of(args.kind === "markdown" ? markdownSupport() : []),
      mode.of(modeExtensions()),
    ]
  }

  const view = new EditorView({ parent, state: EditorState.create({ doc: "" }) })

  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    view.dispatch({ effects: setDiagramTheme.of(currentDiagramTheme()) })
  })
  trackCommandKey()

  function scrollToAnchor(fragment: string): boolean {
    const pos = findAnchor(view.state, fragment)
    if (pos === null) return false
    view.dispatch({ effects: EditorView.scrollIntoView(pos, { y: "start", yMargin: 24 }) })
    return true
  }

  function load(args: LoadArgs): void {
    clearTimeout(dirtyCheck)
    clearTimeout(unsavedTextUpdate)
    docId = args.docId
    kind = args.kind
    sourceMode = args.sourceMode
    snapshots.clear()
    const state = EditorState.create({ doc: args.current ?? args.text, extensions: commonExtensions(args) })
    savedDoc = args.current == null ? state.doc : state.toText(args.text)
    reportedDirty = !state.doc.eq(savedDoc)
    post({ type: "dirty", docId, dirty: reportedDirty })
    view.setState(state)
    view.scrollDOM.scrollTop = 0

    if (kind === "text") {
      const description = LanguageDescription.matchFilename(languages, args.fileName)
      description?.load().then((support) => {
        if (docId === args.docId) view.dispatch({ effects: language.reconfigure(support) })
      })
    }
    if (args.anchor) {
      const anchor = args.anchor
      requestAnimationFrame(() => scrollToAnchor(anchor))
    }
  }

  return {
    view,

    load,

    setSourceMode(on: boolean): void {
      if (sourceMode === on) return
      sourceMode = on
      view.dispatch({ effects: mode.reconfigure(modeExtensions()) })
    },

    snapshot(id: number): Snapshot | null {
      if (id !== docId) return null
      const snapshotId = ++snapshotCounter
      snapshots.set(snapshotId, view.state.doc)
      return { snapshotId, text: view.state.sliceDoc(), dirty: !view.state.doc.eq(savedDoc) }
    },

    markSaved(id: number, snapshotId: number): void {
      const doc = snapshots.get(snapshotId)
      if (id !== docId || !doc) return
      snapshots.clear()
      savedDoc = doc
      clearTimeout(dirtyCheck)
      setDirty(!view.state.doc.eq(savedDoc))
    },

    /** Applies an on-disk change as one minimal edit so the caret and scroll position survive. */
    replaceText(id: number, text: string): void {
      if (id !== docId) return
      const next = view.state.toText(text)
      const change = minimalChange(view.state.doc, next)
      if (change) {
        applyingExternalChange = true
        try {
          view.dispatch({ changes: { from: change.from, to: change.to, insert: next.slice(change.from, change.insertTo) } })
        } finally {
          applyingExternalChange = false
        }
      }
      savedDoc = view.state.doc
      clearTimeout(dirtyCheck)
      setDirty(false)
    },

    reveal(id: number, lineNumber: number, column: number, length: number): void {
      if (id !== docId) return
      const doc = view.state.doc
      const line = doc.line(Math.min(Math.max(lineNumber, 1), doc.lines))
      const from = Math.min(line.from + column, line.to)
      const to = Math.min(from + length, line.to)
      view.dispatch({
        selection: { anchor: from, head: to },
        effects: [EditorView.scrollIntoView(from, { y: "center" }), flashRange.of({ from, to })],
      })
      setTimeout(() => view.dispatch({ effects: flashRange.of(null) }), 1600)
    },

    scrollToAnchor,

    focus(): void {
      view.focus()
    },

    getText(id: number): string | null {
      return id === docId ? view.state.sliceDoc() : null
    },

    /** Applies a programmatic edit (e.g. replace-in-files) as one undoable, minimal user change. */
    applyText(id: number, text: string): void {
      if (id !== docId) return
      const next = view.state.toText(text)
      const change = minimalChange(view.state.doc, next)
      if (change) {
        view.dispatch({
          changes: { from: change.from, to: change.to, insert: next.slice(change.from, change.insertTo) },
          userEvent: "input.replace",
        })
      }
    },

    find: {
      setQuery(id: number, options: FindOptions): void {
        if (id !== docId) return
        setFindQuery(view, options)
        reportFind()
      },
      next(id: number, wrap: boolean): void {
        if (id === docId) reportFind(findNext(view, wrap))
      },
      previous(id: number, wrap: boolean): void {
        if (id === docId) reportFind(findPrevious(view, wrap))
      },
      replace(id: number, wrap: boolean): void {
        if (id === docId) reportFind(replaceCurrent(view, wrap))
      },
      replaceAll(id: number): number {
        if (id !== docId) return 0
        const count = replaceAllMatches(view)
        reportFind()
        return count
      },
      selectAll(id: number): void {
        if (id === docId) reportFind(selectAllMatches(view))
      },
      close(): void {
        closeFind(view)
      },
    },
  }
}

export type EditorAPI = ReturnType<typeof createEditor>
