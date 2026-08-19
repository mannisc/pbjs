import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The bridge script is written for a browser: it touches window, document,
    // Event and DOMException, and it is delivered by string substitution into a
    // <script> tag. jsdom is the closest thing to that a CI runner can host.
    environment: "jsdom",
    include: ["js/**/*.test.js"],
    // Each file loads the bridge into the same jsdom window (see js/harness.js),
    // so isolate per file — one file's leftover globals must not reach another's.
    isolate: true,
  },
});
