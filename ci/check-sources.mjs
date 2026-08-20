// ============================================================================
// Static checks over the PureBasic sources — no compiler required.
// ============================================================================
// This exists because the real gate (pbcompiler --check) cannot run on a
// GitHub-hosted runner: the free PureBasic caps source files at 800 lines each
// and modules/JSWindow.pb is ~3,500, while the licensed compiler is a
// per-user, login-gated download that would be a licensing question to install
// on a public runner. See .github/workflows/ci.yml.
//
// So this is deliberately a WEAKER, DIFFERENT gate — not a stand-in for the
// compiler and not pretending to be one. What earns its place is that both
// real bugs Phase 1 fixed are in the class it catches:
//
//   * `UseModule Ptym` — a module that exists only in the host app, which made
//     pbjs uncompilable standalone (roadmap 1.1).
//   * `IncludeBinary "react/main-window/dist/index.html"` — a path that does
//     not exist in this repo (roadmap 1.3).
//
// Both are resolvable by reading the tree. Neither needs a compiler.
//
// The same class of leak reaches the TypeScript client: pbjsClient/ was
// extracted from the host app it was written inside, and the thing that keeps
// it portable is that it names no app. Check 3 makes that a gate rather than an
// intention — see roadmap 2.9.
//
// Usage:  node ci/check-sources.mjs
// ============================================================================

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, dirname, resolve, relative } from "node:path";

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), "..");

// Directories that are not part of the library's own sources.
const SKIP_DIRS = new Set([
  "node_modules",
  ".git",
  "dist",
  ".claude", // worktrees of in-flight work — not the shipped tree
]);

function walk(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") && entry.name !== ".github") {
      if (SKIP_DIRS.has(entry.name)) continue;
    }
    if (SKIP_DIRS.has(entry.name)) continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.name.endsWith(".pb")) out.push(full);
  }
  return out;
}

const problems = [];
const note = (file, line, msg) =>
  problems.push(`${relative(ROOT, file)}:${line}  ${msg}`);

const sources = walk(ROOT).sort();
if (sources.length === 0) {
  console.error("No .pb sources found — is this the right directory?");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// 1. Every Include*/XIncludeFile path resolves.
// ---------------------------------------------------------------------------
// PureBasic resolves these RELATIVE TO THE FILE CONTAINING THE DIRECTIVE (not
// the compiled entry point, and not the cwd) — verified against 6.21.
//
// IncludeBinary targets that live under a gitignored dist/ are reported as a
// note, not a failure: they are legitimately absent until the web app is built.
const INCLUDE_RE = /^\s*(X?IncludeFile|IncludeBinary)\s+"([^"]+)"/i;
let includeCount = 0;
let unbuiltCount = 0;

for (const file of sources) {
  const lines = readFileSync(file, "utf8").split(/\r?\n/);
  lines.forEach((text, i) => {
    if (/^\s*;/.test(text)) return; // comment
    const m = text.match(INCLUDE_RE);
    if (!m) return;
    includeCount++;
    const [, kind, target] = m;
    const abs = resolve(dirname(file), target);
    if (existsSync(abs)) return;

    // A missing dist/ target is only excusable if everything ABOVE dist/ is
    // real — i.e. the web app exists and merely has not been built. Excusing
    // any path containing "dist/" is too generous: it is exactly how
    // example.pb pointed at `react/main-window/dist/index.html` in a repo whose
    // web app lives at `reactExample/`, and nothing noticed.
    const distIdx = target.split("/").indexOf("dist");
    if (distIdx > 0) {
      const base = resolve(dirname(file), target.split("/").slice(0, distIdx).join("/"));
      if (existsSync(base)) {
        unbuiltCount++;
        return; // built artifact, gitignored — not a source error
      }
      note(
        file,
        i + 1,
        `${kind} target does not exist: ${target} — and neither does the ` +
          `directory above dist/, so this is a wrong path, not an unbuilt one.`
      );
      return;
    }
    note(file, i + 1, `${kind} target does not exist: ${target}`);
  });
}

// ---------------------------------------------------------------------------
// 2. Every UseModule names a module declared somewhere in this repo.
// ---------------------------------------------------------------------------
// This is the `UseModule Ptym` check. A module that resolves only because the
// host app happened to include it first is invisible locally and fatal for
// anyone else.
const declared = new Set();
for (const file of sources) {
  for (const m of readFileSync(file, "utf8").matchAll(
    /^\s*DeclareModule\s+([A-Za-z_]\w*)/gim
  )) {
    declared.add(m[1].toLowerCase());
  }
}

for (const file of sources) {
  const lines = readFileSync(file, "utf8").split(/\r?\n/);
  lines.forEach((text, i) => {
    if (/^\s*;/.test(text)) return;
    const m = text.match(/^\s*UseModule\s+([A-Za-z_]\w*)/i);
    if (!m) return;
    const name = m[1];
    if (declared.has(name.toLowerCase())) return;
    note(
      file,
      i + 1,
      `UseModule ${name} — no DeclareModule ${name} in this repo. If it comes ` +
        `from the host app, pbjs will not compile standalone; make the ` +
        `coupling optional with CompilerIf Defined(${name}, #PB_Module).`
    );
  });
}

// ---------------------------------------------------------------------------
// 3. The TypeScript client names no host app.
// ---------------------------------------------------------------------------
// pbjsClient/ is a library: it takes everything app-specific through
// configureHost() and must not know who is embedding it. A host name that
// creeps back in is the JS twin of `UseModule Ptym` — it compiles fine here,
// and is wrong for every other consumer.
//
// Deliberately a name check, not a lint rule: the failure is about vocabulary,
// and it has to fail in a repo that has no TypeScript toolchain of its own.
const CLIENT_DIR = join(ROOT, "pbjsClient");
const HOST_TERMS = [
  /\bvynce\b/i,
  /\bptym\b/i,
  /__vynceWebAdapter\b/,
  /\bVYNCE_[A-Z0-9_]+/,
  /\b(?:main|agent|execution)-window\b/,
  /\bAgentStore\b/,
  /\bagent-list\.json\b/,
];

let clientFiles = [];
if (existsSync(CLIENT_DIR)) {
  clientFiles = readdirSync(CLIENT_DIR)
    .filter((n) => n.endsWith(".ts"))
    .map((n) => join(CLIENT_DIR, n))
    .sort();

  for (const file of clientFiles) {
    readFileSync(file, "utf8")
      .split(/\r?\n/)
      .forEach((text, i) => {
        for (const re of HOST_TERMS) {
          const m = text.match(re);
          if (!m) continue;
          note(
            file,
            i + 1,
            `"${m[0]}" names a host app. pbjsClient/ must stay portable — ` +
              `move it behind PbjsHostHooks (configureHost) instead.`
          );
          break;
        }
      });
  }
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------
console.log(
  `Checked ${sources.length} PureBasic sources: ` +
    `${includeCount} include directives, ${declared.size} modules declared.`
);
console.log(
  clientFiles.length
    ? `Checked ${clientFiles.length} client source(s) in pbjsClient/ for host-app names.`
    : "No pbjsClient/ sources found — skipping the portability check."
);
if (unbuiltCount) {
  console.log(
    `${unbuiltCount} IncludeBinary target(s) under dist/ not present — ` +
      `expected before the web app is built.`
  );
}

if (problems.length) {
  console.error(`\n${problems.length} problem(s):\n`);
  for (const p of problems) console.error("  " + p);
  process.exit(1);
}
console.log("OK — no unresolved includes, no host-only modules, no host names in the client.");
