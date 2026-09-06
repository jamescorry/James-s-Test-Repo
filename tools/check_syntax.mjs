#!/usr/bin/env node
// Parse every Monkey C source file and report syntax errors.
//
// The Connect IQ compiler is the real authority, but it needs the SDK and
// device files, which require a Garmin account. This check uses the
// open-source Monkey C parser behind the prettier plugin instead, so a
// syntax error is caught on any machine with Node - no SDK, no account.
//
// It parses only: it will not catch type errors, unknown API calls, or
// anything else that needs the SDK. Run scripts/build.sh for that.

import * as prettier from "prettier";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceRoot = path.join(repoRoot, "source");

const files = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full);
    } else if (entry.name.endsWith(".mc")) {
      files.push(full);
    }
  }
})(sourceRoot);

let failed = 0;
for (const file of files.sort()) {
  const relative = path.relative(repoRoot, file);
  try {
    await prettier.format(fs.readFileSync(file, "utf8"), {
      parser: "monkeyc",
      plugins: ["@markw65/prettier-plugin-monkeyc"],
    });
    console.log(`ok    ${relative}`);
  } catch (error) {
    failed++;
    console.log(`FAIL  ${relative}`);
    console.log(
      String(error.message)
        .split("\n")
        .slice(0, 8)
        .map((line) => `      ${line}`)
        .join("\n")
    );
  }
}

console.log(`\n${files.length - failed}/${files.length} files parsed`);
process.exit(failed > 0 ? 1 : 0);
