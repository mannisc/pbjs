import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// https://vite.dev/config/
export default defineConfig({
  base: "./",
  plugins: [
    react({
      babel: {
        plugins: [["babel-plugin-react-compiler"]],
      },
    }),
    viteSingleFile(),
  ],
  build: {
    assetsInlineLimit: 100 * 1024 * 1024, // inline all assets
    outDir: "dist",
    rollupOptions: {
      output: {
        manualChunks: undefined, // disable code splitting
        entryFileNames: "main.js",
        chunkFileNames: "main.js",
        assetFileNames: "[name].[ext]",
      },
    },
  },
});
