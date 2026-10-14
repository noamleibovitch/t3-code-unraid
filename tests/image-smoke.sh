#!/usr/bin/env bash
# Bounded runtime smoke test for the published T3 Code image.
#
# Usage: bash tests/image-smoke.sh <image-reference>
#        bash tests/image-smoke.sh --self-test (offline workflow regression tests)
#
# The reference may be a tag or a digest reference, and it must already be
# present in the local Docker store: the container is started with
# `--pull=never` so a cold registry pull can never be charged against the
# per-call 15s Docker budget. The release workflow bound-pulls the exact
# candidate digest before invoking this script. This is a release gate: it
# launches the image's default entrypoint with disposable storage and no
# credentials, waits for a bounded ready HTTP response, then asserts the
# runtime/security contract before sending a normal SIGTERM.
#
# It fails on: early container exit, startup timeout, wrong PID 1 ownership,
# a non-native T3 PID 1, a provider prefix that is not writable by the app
# user, root-owned launch paths that are not root-owned, provider CLI failure
# as the app user, or a shutdown that requires SIGKILL/OOM termination.
set -euo pipefail

if [ "$#" -eq 1 ] && [ "$1" = --self-test ]; then
    exec python3 - "$0" <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

# Exercise the actual workflow shell blocks against synthetic Buildx responses.
# This tests release-gate logic; it does not certify a real image or registry.
workflow = (Path(sys.argv[1]).resolve().parents[1] / ".github/workflows/build-ghcr.yml").read_text()
steps = {}
name = None
lines = workflow.splitlines()
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("      - name: "):
        name = line.split(": ", 1)[1]
    if line == "        run: |":
        i += 1
        body = []
        while i < len(lines) and (lines[i].startswith("          ") or not lines[i].strip()):
            body.append(lines[i][10:])
            i += 1
        steps[name] = "\n".join(body) + "\n"
    else:
        i += 1

# The smoke's readiness acceptance must mirror the shipped healthcheck
# contract (200 <= status < 500 with redirect handling manual), or the gate
# would spuriously reject a container that the image itself considers healthy.
def accepted_status_range(text):
    match = re.search(r"status >= (\d+) && response\.status < (\d+)", text)
    assert match, "ready status range not found"
    return int(match.group(1)), int(match.group(2))

repo_root = Path(sys.argv[1]).resolve().parents[1]
assert accepted_status_range(Path(sys.argv[1]).read_text()) == \
    accepted_status_range((repo_root / "healthcheck.sh").read_text()) == (200, 500)

candidate, image, config, provenance, sbom, promoted = ["sha256:" + c * 64 for c in "abcdef"]
def descriptor(digest, size, arch="unknown", **annotations):
    return {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": digest,
            "size": size, "platform": {"os": "linux" if arch == "amd64" else "unknown", "architecture": arch},
            "annotations": annotations}
annotations = {"vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": image}
index = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [
    descriptor(image, 100, "amd64"), descriptor(provenance, 200, **annotations), descriptor(sbom, 300, **annotations)]}
attestation = lambda predicate: {"layers": [{"annotations": {"in-toto.io/predicate-type": predicate}}]}
with tempfile.TemporaryDirectory(prefix="t3-release-gate-tests-") as temporary:
    root = Path(temporary)
    docker = root / "docker"
    docker.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
failure = os.environ.get("FAIL_DOCKER", "")
if args[:1] == ["pull"]:
    # The smoke step must bound-pull the exact IMAGE_REF itself; record the
    # ref so the stubbed smoke can prove the pull happened before it ran.
    assert args[1:] == [os.environ["IMAGE_REF"]], args
    if failure == "pull":
        sys.exit(1)
    (pathlib.Path(os.environ["FIXTURES"]) / "pulled").write_text(os.environ["IMAGE_REF"])
    sys.exit(0)
assert args[:2] == ["buildx", "imagetools"], args
if args[2] == "create":
    assert args[3:] == ["--tag", "ghcr.io/test/t3:stable", "ghcr.io/test/t3@" + os.environ["CANDIDATE"]], args
    sys.exit(1 if failure == "promotion" else 0)
if "--format" in args:
    if failure == "format": sys.exit(1)
    print(os.environ["PROMOTED"])
else:
    digest = args[-1].split("@")[-1]
    if failure == "raw" and digest == os.environ["PROMOTED"]: sys.exit(1)
    print((pathlib.Path(os.environ["FIXTURES"]) / digest).read_text())
''')
    docker.chmod(0o755)
    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
               FIXTURES=str(root), CANDIDATE=candidate, PROMOTED=promoted,
               REGISTRY="ghcr.io", IMAGE_NAME="test/t3", IMAGE_REF="ghcr.io/test/t3@" + candidate,
               GITHUB_WORKSPACE=str(root),
               GITHUB_OUTPUT=str(root / "outputs"), GITHUB_STEP_SUMMARY=str(root / "summary"))
    def fixture(digest, data):
        (root / digest).write_text(json.dumps(data))
    def run(name, success=True, failure="", descriptor_mismatch=False, extra_env=None):
        (root / "pulled").unlink(missing_ok=True)
        script = re.sub(r"\$\{\{ steps\.build\.outputs\.digest \}\}", candidate, steps[name])
        script = re.sub(r"\$\{\{.*?\}\}", "fixture", script)
        result = subprocess.run(["bash", "-c", script], cwd=root,
                                env=dict(env, FAIL_DOCKER=failure, **(extra_env or {})),
                                capture_output=True, text=True, timeout=10)
        assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
        if not success and ("Promote" in name or "promoted" in name):
            assert "stable may already have moved" in result.stderr, result.stderr
        if descriptor_mismatch:
            assert "--- candidate-descriptors.jsonl" in result.stdout and "+++ stable-descriptors.jsonl" in result.stdout, result.stdout
    inspect = "Inspect candidate index"
    verify = "Verify promoted stable descriptors match candidate"
    fixture(candidate, index)
    fixture(image, {"config": {"digest": config}})
    fixture(provenance, attestation("https://slsa.dev/provenance/v1"))
    fixture(sbom, attestation("https://spdx.dev/Document"))
    run(inspect)  # Separate provenance and SBOM manifests must be supported.
    for digest in (provenance, sbom):
        original = (root / digest).read_text()
        fixture(digest, attestation("https://invalid.example/predicate"))
        run(inspect, False)
        (root / digest).write_text(original)
    fixture(image, {"config": {"digest": None}})
    run(inspect, False)
    fixture(image, {"config": {"digest": config}})
    malformed = copy.deepcopy(index)
    malformed["manifests"][2]["annotations"]["vnd.docker.reference.digest"] = config
    fixture(candidate, malformed)
    run(inspect, False)
    fixture(candidate, index)
    run(inspect)
    reordered = copy.deepcopy(index)
    reordered["manifests"].reverse()
    fixture(promoted, reordered)
    run(verify)  # A different index digest with reordered descriptors is valid.
    mutations = []
    for operation in ("missing", "added", "duplicated", "digest", "mediaType", "size", "platform", "annotations"):
        changed = copy.deepcopy(index)
        descriptors = changed["manifests"]
        if operation == "missing": descriptors.pop()
        elif operation == "added": descriptors.append(descriptor("sha256:" + "0" * 64, 400))
        elif operation == "duplicated": descriptors.append(copy.deepcopy(descriptors[-1]))
        elif operation == "digest": descriptors[-1][operation] = config
        elif operation == "mediaType": descriptors[-1][operation] = "application/vnd.docker.distribution.manifest.v2+json"
        elif operation == "size": descriptors[-1][operation] += 1
        elif operation == "platform": descriptors[-1][operation]["architecture"] = "amd64"
        else: descriptors[-1][operation]["vnd.docker.reference.digest"] = config
        mutations.append(changed)
    for changed in mutations:
        fixture(promoted, changed)
        run(verify, False, descriptor_mismatch=True)
    fixture(promoted, reordered)
    run(verify, False, "format")
    run(verify, False, "raw")
    # The smoke step must bounded-pull the exact IMAGE_REF before invoking the
    # smoke, then bind the running container to the inspected amd64
    # configuration digest: a matching id passes, while a mismatched or
    # malformed id fails before promotion. The smoke script is stubbed so this
    # stays offline and never builds an image or moves a tag. The stub refuses
    # to run unless the pull already recorded the exact IMAGE_REF, which proves
    # the pull is ordered before the smoke (and the pull failure is fatal).
    smoke = "Run bounded image smoke test"
    (root / "tests").mkdir()
    (root / "tests" / "image-smoke.sh").write_text('''#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 1 ] || exit 64
[ -n "${SMOKE_IMAGE_ID:-}" ] || exit 1
[ "$(cat "${FIXTURES}/pulled" 2>/dev/null || true)" = "${IMAGE_REF}" ] || exit 3
echo "SMOKE_IMAGE_ID=${SMOKE_IMAGE_ID}"
''')
    (root / "candidate-config-digest.txt").write_text(config + "\n")
    run(smoke, False, "pull", extra_env={"SMOKE_IMAGE_ID": config})
    run(smoke, extra_env={"SMOKE_IMAGE_ID": config})
    run(smoke, False, extra_env={"SMOKE_IMAGE_ID": "sha256:" + "9" * 64})
    run(smoke, False, extra_env={"SMOKE_IMAGE_ID": "sha256:not-hex"})
    promote = "Promote verified candidate to stable"
    run(promote)
    run(promote, False, "promotion")
print("PASS: 24 offline release-gate cases (split attestations, missing evidence, descriptor multiset, bounded pre-pull ordering, smoke-to-manifest binding, promotion errors, readiness/healthcheck parity)")
PY
fi

IMAGE_REF="${1:-}"
if [ "$#" -ne 1 ] || [ -z "${IMAGE_REF}" ]; then
    echo "usage: $0 <image-reference>" >&2
    exit 64
fi

PORT="${T3_PORT:-9877}"
CONTAINER="t3-image-smoke-$$"
START_DEADLINE="${SMOKE_START_DEADLINE:-120}"
STOP_DEADLINE="${SMOKE_STOP_DEADLINE:-30}"
APP_UID=10000
APP_GID=10000

for deadline in "${START_DEADLINE}" "${STOP_DEADLINE}"; do
    [[ "${deadline}" =~ ^[1-9][0-9]{0,2}$ ]] && [ "${deadline}" -le 600 ] || {
        echo 'smoke deadlines must be integer seconds from 1 through 600' >&2
        exit 64
    }
done
[[ "${PORT}" =~ ^[1-9][0-9]{0,4}$ ]] && [ "${PORT}" -le 65535 ] || exit 64

# Bound Docker calls as well as polling, including a hung provider CLI.
docker_cmd() {
    timeout --signal=TERM --kill-after=1s 15s docker "$@"
}

docker_until() {
    remaining=$((deadline - SECONDS))
    [ "${remaining}" -gt 0 ] || return 124
    timeout --signal=TERM --kill-after=1s "${remaining}s" docker "$@"
}

cleanup() {
    status=$?
    if [ "${status}" -ne 0 ]; then
        echo "--- image-smoke diagnostics: container logs ---" >&2
        docker_cmd logs "${CONTAINER}" >&2 || true
        echo "--- image-smoke diagnostics: container inspect ---" >&2
        docker_cmd inspect "${CONTAINER}" >&2 || true
    fi
    docker_cmd rm --force --volumes "${CONTAINER}" >/dev/null 2>&1 || true
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "image-smoke FAIL: $*" >&2
    exit 1
}

app_exec() {
    docker_cmd exec --user "${APP_UID}:${APP_GID}" "${CONTAINER}" "$@"
}

docker_cmd run --detach \
    --name "${CONTAINER}" \
    --pull=never \
    --platform linux/amd64 \
    --network none \
    --env "T3_PORT=${PORT}" \
    --mount type=volume,destination=/home/t3 \
    --mount type=volume,destination=/workspace \
    "${IMAGE_REF}" >/dev/null

# Bounded readiness polling against the in-container listener. The check runs
# through `docker exec` and node (both guaranteed present) so no host tooling
# or published port is required. The accepted status range mirrors
# healthcheck.sh: any HTTP 200-499 with redirect handling disabled is healthy.
ready=0
deadline=$((SECONDS + START_DEADLINE))
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if [ "$(docker_until inspect --format '{{.State.Running}}' "${CONTAINER}")" != "true" ]; then
        fail "container exited before it became ready"
    fi
    if docker_until exec --user "${APP_UID}:${APP_GID}" "${CONTAINER}" node -e '
const port = process.argv[1];
fetch("http://127.0.0.1:" + port + "/", {
  redirect: "manual",
  signal: AbortSignal.timeout(3000),
}).then((response) => {
  process.exit(response.status >= 200 && response.status < 500 ? 0 : 1);
}).catch(() => process.exit(1));
' "${PORT}" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if [ "${SECONDS}" -lt "${deadline}" ]; then sleep 1; fi
done
[ "${ready}" -eq 1 ] || fail "ready HTTP response did not succeed within ${START_DEADLINE}s"

# PID 1 must be the native T3 server running as the dedicated app account.
status_file="$(app_exec cat /proc/1/status)"
pid1_uid="$(printf '%s\n' "${status_file}" | sed -n 's/^Uid:[[:space:]]*\([0-9]*\).*/\1/p')"
pid1_gid="$(printf '%s\n' "${status_file}" | sed -n 's/^Gid:[[:space:]]*\([0-9]*\).*/\1/p')"
[ "${pid1_uid}" = "${APP_UID}" ] || fail "PID 1 runs as uid ${pid1_uid}, expected ${APP_UID}"
[ "${pid1_gid}" = "${APP_GID}" ] || fail "PID 1 runs as gid ${pid1_gid}, expected ${APP_GID}"

pid1_exe="$(app_exec readlink /proc/1/exe)"
case "${pid1_exe}" in
    *"@t3code/t3-linux-x64/t3") ;;
    *) fail "PID 1 is not the native T3 binary: ${pid1_exe}" ;;
esac

# Provider prefix must be writable by the app user for in-UI updates.
app_exec sh -eu -c '
    for dir in /opt/t3-providers /opt/t3-providers/bin /opt/t3-providers/lib/node_modules; do
        test "$(stat -c "%u:%g" "$dir")" = 10000:10000
        probe="$(mktemp -d "$dir/.smoke.XXXXXX")"
        rmdir "$probe"
    done
' \
    || fail "provider prefix /opt/t3-providers is not writable by ${APP_UID}:${APP_GID}"

# T3 itself and the launch symlinks must stay root-owned so the app cannot
# replace the code the root Unraid hook executes.
owner_of() {
    app_exec stat -c '%u:%g' "$1"
}
[ "$(owner_of /usr/local/lib/node_modules/t3)" = "0:0" ] || fail "/usr/local/lib/node_modules/t3 is not root-owned"
[ "$(owner_of /usr/local/bin/t3)" = "0:0" ] || fail "/usr/local/bin/t3 is not root-owned"
[ "$(owner_of /usr/local/bin/codex)" = "0:0" ] || fail "/usr/local/bin/codex is not root-owned"
[ "$(owner_of /usr/local/bin/opencode)" = "0:0" ] || fail "/usr/local/bin/opencode is not root-owned"

# Ownership alone does not protect a group/world-writable file or its parent.
# Resolve the packaged binary exactly, and check launch directories and PATH
# as the app user, without following the writable provider targets as root.
app_exec node -e '
const fs = require("node:fs");
const { createRequire } = require("node:module");
const { dirname, join } = require("node:path");
const requireT3 = createRequire("/usr/local/lib/node_modules/t3/package.json");
const native = fs.realpathSync(join(dirname(requireT3.resolve("@t3code/t3-linux-x64/package.json")), "t3"));
if (fs.realpathSync("/proc/1/exe") !== native) throw new Error("PID 1 is not the packaged native T3 binary");
const status = fs.readFileSync("/proc/1/status", "utf8");
for (const key of ["Uid", "Gid"]) {
  const match = status.match(new RegExp("^" + key + ":\\s+(.+)$", "m"));
  if (!match || match[1].trim().split(/\s+/).some(value => value !== "10000"))
    throw new Error("PID 1 has unexpected " + key + " credentials");
}
const protectedPaths = new Set(["/usr/local/lib/node_modules/t3/bin/t3.js", native]);
for (const p of [...protectedPaths, "/usr/local/bin", "/opt", ...process.env.PATH.split(":")]) {
  if (!p.startsWith("/")) throw new Error("relative or empty PATH entry: " + p);
  for (let path = p;; path = dirname(path)) {
    protectedPaths.add(path);
    if (path === "/") break;
  }
}
for (const path of protectedPaths) {
  const stat = fs.statSync(path);
  if (stat.uid !== 0 || stat.gid !== 0) throw new Error("not root-owned: " + path);
  try { fs.accessSync(path, fs.constants.W_OK); }
  catch (error) { if (error.code === "EACCES") continue; throw error; }
  throw new Error("app can write protected path: " + path);
}
for (const name of ["t3", "codex", "opencode"]) {
  const path = "/usr/local/bin/" + name;
  if (!fs.lstatSync(path).isSymbolicLink()) throw new Error("not a launch symlink: " + path);
}
' || fail "native T3, protected launch paths, or image PATH violated the security contract"

# Execute the real provider CLIs (and the T3 launcher) as the app user.
app_exec codex --version >/dev/null || fail "codex CLI failed to run as ${APP_UID}:${APP_GID}"
app_exec opencode --version >/dev/null || fail "opencode CLI failed to run as ${APP_UID}:${APP_GID}"
app_exec t3 --version >/dev/null || fail "t3 launcher failed to run as ${APP_UID}:${APP_GID}"

# Emit the running container's image ID so the caller can tie the smoke result
# to the exact inspected manifest configuration digest.
image_id="$(docker_cmd inspect --format '{{.Image}}' "${CONTAINER}")"

# Normal SIGTERM must stop the container within the deadline without a forced
# SIGKILL (exit 137) or an OOM kill.
docker_cmd kill --signal=TERM "${CONTAINER}" >/dev/null
stopped=0
stop_started=${SECONDS}
deadline=$((SECONDS + STOP_DEADLINE))
while [ "${SECONDS}" -lt "${deadline}" ]; do
    if [ "$(docker_until inspect --format '{{.State.Running}}' "${CONTAINER}")" = "false" ]; then
        stopped=1
        break
    fi
    sleep 1
done
[ "${stopped}" -eq 1 ] || fail "container did not stop within ${STOP_DEADLINE}s after SIGTERM (forced termination required)"

exit_code="$(docker_cmd inspect --format '{{.State.ExitCode}}' "${CONTAINER}")"
oom_killed="$(docker_cmd inspect --format '{{.State.OOMKilled}}' "${CONTAINER}")"
[ "${oom_killed}" = "false" ] || fail "container was OOM-killed on shutdown"
[ "${exit_code}" != "137" ] || fail "container was force-killed (exit 137) instead of handling SIGTERM"
case "${exit_code}" in
    0|143) ;;
    *) fail "container exited abnormally after SIGTERM (exit ${exit_code})" ;;
esac

echo "SMOKE_IMAGE_ID=${image_id}"
echo "image-smoke PASS: ${IMAGE_REF} (exit ${exit_code}, shutdown within $((SECONDS - stop_started))s, no OOM/SIGKILL)" >&2
