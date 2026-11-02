import { defineConfig } from "vitest/config"

export default defineConfig({
  base: "./",
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "safari17",
    chunkSizeWarningLimit: 4096,
    sourcemap: false,
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./test/setup.ts"],
  },
})
