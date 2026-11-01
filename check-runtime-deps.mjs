#!/usr/bin/env node
// Build-time gate: fail the image build when the pinned T3 standalone runtime
// cannot start on THIS base image.
//
// T3 0.1.6 ships an official standalone archive whose complete tree contains
// the native `t3` executable plus node_modules/, client/, and resource-monitor/.
// The image installs that tree root-owned at /opt/t3 and executes /opt/t3/t3
// directly as PID 1. There is no npm-installed package or @t3code platform
// package to resolve: the npm launcher would perform a mutable first-run
// download into writable T3CODE_HOME, which this image deliberately avoids.
//
// Rationale (regression observed in production): older T3 binaries linked
// libatomic.so.1, which the slim Node base did not ship at the time. Because
// nothing at build time executed the real binary, the image built and published
// successfully while the container exited 127 on start. Inspecting and running
// the exact packaged binary here turns that runtime crash into a failed build.

import { execFileSync } from "node:child_process";
import { lstatSync, realpathSync, statSync } from "node:fs";
import { join } from "node:path";

const expectedVersion = "t3 v0.1.6";
const t3Root = "/opt/t3";
const binary = join(t3Root, "t3");
const launcher = "/usr/local/bin/t3";

function fail(message) {
  console.error(message);
  process.exit(1);
}

function inspect(path, { symlink = false } = {}) {
  try {
    return (symlink ? lstatSync : statSync)(path);
  } catch (error) {
    fail(`cannot inspect ${path}: ${error.message}`);
  }
}

// Protect the shipped application tree and its launch path: root-owned and not
// group/world-writable, so the unprivileged application cannot replace code
// that the root Unraid Tailscale hook executes.
for (const path of ["/", "/opt", t3Root, binary, "/usr/local/bin", launcher]) {
  const stats = inspect(path, { symlink: path === launcher });
  if (stats.uid !== 0 || stats.gid !== 0) {
    fail(`${path} must be root-owned; got ${stats.uid}:${stats.gid}`);
  }
  if (path !== launcher && (stats.mode & 0o022) !== 0) {
    fail(`${path} must not be group/world-writable; mode ${(stats.mode & 0o777).toString(8)}`);
  }
}

for (const directory of ["node_modules", "client", "resource-monitor"]) {
  const path = join(t3Root, directory);
  const stats = inspect(path);
  if (!stats.isDirectory()) fail(`${path} must be a directory in the standalone tree`);
}

if (!inspect(launcher, { symlink: true }).isSymbolicLink()) {
  fail(`${launcher} must be a symlink to ${binary}`);
}
if (realpathSync(launcher) !== realpathSync(binary)) {
  fail(`${launcher} must resolve to ${binary}`);
}

// The providers live in a dedicated application-owned prefix so T3 can update
// them from its UI. Refuse to build if that prefix is not actually owned by the
// application user, because the failure only shows up later as an opaque
// "Update command exited with code 243" in the UI.
const providerPrefix = process.env.T3_PROVIDER_PREFIX || "/opt/t3-providers";
const providerRoot = join(providerPrefix, "lib", "node_modules");
try {
  const stats = statSync(providerRoot);
  if (stats.uid !== 10000 || stats.gid !== 10000) {
    console.error(
      `${providerRoot} must be owned by 10000:10000 for in-UI provider updates; got ${stats.uid}:${stats.gid}`,
    );
    process.exit(1);
  }
} catch (error) {
  console.error(`cannot inspect provider prefix ${providerRoot}: ${error.message}`);
  process.exit(1);
}

// The providers are on PATH; prove they resolve and run, so a broken shim or a
// skipped install script fails the build instead of the container.
for (const [command, args] of [
  ["codex", ["--version"]],
  ["opencode", ["--version"]],
]) {
  try {
    const output = execFileSync(command, args, { encoding: "utf8" }).trim();
    console.log(`${command} runtime OK: ${output.split("\n")[0]}`);
  } catch (error) {
    console.error(`${command} failed to run from ${providerPrefix}: ${error.message}`);
    process.exit(1);
  }
}

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

// Prove the binary actually starts, not merely that ldd is satisfied, and pin
// the exact version installed by this build.
let version;
try {
  version = execFileSync(binary, ["--version"], { encoding: "utf8" }).trim();
} catch (error) {
  fail(`${binary} failed to start: ${error.message}`);
}
if (version !== expectedVersion) {
  fail(`unexpected t3 version output: ${version}; expected ${expectedVersion}`);
}

// The entrypoint depends on these exact serve flags. Validate the installed
// artifact rather than assuming the source interface survived packaging.
let serveHelp;
try {
  serveHelp = execFileSync(binary, ["serve", "--help"], { encoding: "utf8" });
} catch (error) {
  fail(`${binary} serve --help failed: ${error.message}`);
}
if (!/\bt3 serve\b/.test(serveHelp)) {
  fail("installed t3 does not describe a serve command");
}
for (const flag of ["--host", "--port", "--base-dir", "--no-browser"]) {
  if (!serveHelp.includes(flag)) {
    fail(`installed t3 serve --help is missing ${flag}`);
  }
}

// The `t3` on PATH is what the container actually runs; exercise it too so a
// stale or wrong symlink cannot pass while shipping the wrong launcher.
let launcherVersion;
try {
  launcherVersion = execFileSync("t3", ["--version"], { encoding: "utf8" }).trim();
} catch (error) {
  fail(`t3 launcher failed to run: ${error.message}`);
}
if (launcherVersion !== version) {
  fail(`t3 on PATH reported "${launcherVersion}", expected "${version}"`);
}

console.log(`t3 runtime OK: ${version} (${binary}; standalone tree)`);
