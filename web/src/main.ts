import "github-markdown-css/github-markdown.css"
import "katex/dist/katex.min.css"
import "./styles/app.css"
import { post } from "./bridge"
import { createEditor, type EditorAPI } from "./editor"

declare global {
  interface Window {
    mdb: EditorAPI
  }
}

window.addEventListener("error", (event) => post({ type: "error", message: String(event.message) }))
window.addEventListener("unhandledrejection", (event) => post({ type: "error", message: String(event.reason) }))

window.mdb = createEditor(document.getElementById("editor")!)
post({ type: "ready" })
