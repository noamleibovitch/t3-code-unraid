#!/usr/bin/env node
// Build-time gate: fail the image build when the pinned T3 native binary cannot
// start on THIS base image.
//
// Rationale (regression observed in production): T3 0.0.42's linux-x64 binary
// links libatomic.so.1, which node:22-bookworm-slim does not ship. Because
// nothing at build time executed the real binary, the image built and published
// successfully while the container exited 127 on start:
//   ".../@t3code/t3-linux-x64/t3: error while loading shared libraries:
//    libatomic.so.1: cannot open shared object file"
// Resolving the package's entry point and running it here turns that runtime
// crash into a failed build.

import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";

const require = createRequire("/usr/local/lib/node_modules/t3/package.json");
const key = `${process.platform}-${process.arch}`;

let packageDir;
try {
  packageDir = dirname(require.resolve(`@t3code/t3-${key}/package.json`));
} catch (error) {
  console.error(`no T3 Code CLI build installed for ${key}: ${error.message}`);
  process.exit(1);
}

const binary = join(packageDir, process.platform === "win32" ? "t3.exe" : "t3");

if (process.platform !== "linux") {
  console.log(`skipping ELF dependency check on ${process.platform}`);
  process.exit(0);
}

const ldd = execFileSync("ldd", [binary], { encoding: "utf8" });
const unresolved = ldd
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line.includes("not found"));

if (unresolved.length > 0) {
  console.error(`unresolved shared libraries for ${binary}:`);
  for (const line of unresolved) console.error(`  ${line}`);
  process.exit(1);
}

// Prove the binary actually starts, not merely that ldd is satisfied.
const version = execFileSync(binary, ["--version"], { encoding: "utf8" }).trim();
if (!version.startsWith("t3 v")) {
  console.error(`unexpected t3 version output: ${version}`);
  process.exit(1);
}

// The `t3` on PATH is what the container actually runs; a stale symlink kept the
// 0.0.41 assertion passing while shipping the wrong launcher, so exercise it too.
const launcher = execFileSync("t3", ["--version"], { encoding: "utf8" }).trim();
if (launcher !== version) {
  console.error(`t3 on PATH reported "${launcher}", expected "${version}"`);
  process.exit(1);
}

console.log(`t3 runtime OK: ${version} (${binary})`);
