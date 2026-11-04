import { defineConfig } from "vite"

// Builds search-engine.js next to the editor bundle; run after the main build, which empties the folder.
export default defineConfig({
  build: {
    outDir: "dist",
    emptyOutDir: false,
    target: "safari17",
    sourcemap: false,
    copyPublicDir: false,
    lib: {
      entry: "src/search/bundle.ts",
      formats: ["iife"],
      name: "mdbSearch",
      fileName: () => "search-engine.js",
    },
  },
})
