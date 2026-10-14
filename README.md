# T3 Code container build context for Unraid

This directory is a local Docker build context for a headless T3 Code server. It does not contain credentials. On Unraid 7+, the Docker template's native Tailscale integration owns private HTTPS access.

## Build boundary

**Build this image on a Docker-capable host or in CI.** The GitHub Actions workflow is the preferred publication path and does not require a Docker socket on Hermes or Unraid.

Example build on a Docker-capable host:

```sh
docker build --pull --no-cache --tag t3-code-unraid:0.0.45 /opt/data/t3-code-unraid
```

No remote `latest` tag is used. The direct tool versions are pinned as follows:

| Component | Pinned version/source |
| --- | --- |
| Node.js | `node:24-bookworm-slim` (latest supported LTS major) |
| T3 Code (`t3`) | `0.0.45` |
| Codex CLI (`@openai/codex`) | `0.162.1` |
| OpenCode CLI (`opencode-ai`) | `1.19.0` |
| GitHub CLI (`gh`) | `2.102.0` |
| Ollama Cloud client (`ollama`) | `0.40.4` |

From `t3` `0.0.41` onward the npm package ships a launcher at `bin/t3.js` and
resolves its platform binary from `@t3code/t3-<platform>-<arch>`. The image links
`/usr/local/bin/t3` to that launcher; the older `dist/bin.mjs` path still exists
but is no longer the declared entry point. Version pins are asserted in both
build stages, so a mismatch fails the image build instead of shipping silently.

The GitHub CLI and Ollama client archives are selected for Debian `amd64` or `arm64` and checked against release SHA-256 values before installation. The final image contains only the Ollama client binary: it does not run a local Ollama server, include model storage, or require a GPU.

The refresh uses the supplied release evidence dated 2026-10-14 (`.workflow-kit/release-evidence.json` and `.workflow-kit/context/verified-releases.md`). No downloads were performed in the network-disabled implementation session. Official archive availability and downloaded-byte checksum verification remain release prerequisites; the Dockerfile fails closed on either a download or checksum error. CI builds amd64 only, so the arm64 archive still needs separate verification before claiming arm64 support.

## Runtime contract

- The Unraid Tailscale hook starts as root because it must initialize Tailscale. The image entrypoint then immediately drops privileges and runs T3 as `t3` (UID/GID `10000:10000`, matching the `hermes` appdata owner on this Unraid host).
- The root phase of the entrypoint deliberately resets `PATH` before `exec gosu`. The image ships no user-writable directory on `PATH`, and the reset keeps it that way even if a caller passes one in the environment. Without it, anything able to write to such a directory could shadow a binary that the root context executes. Do not remove that reset.
- `/workspace` is the expected project bind mount and the container working directory.
- `T3_PORT` controls both the T3 listener and the health check; its default is `9877`.
- T3 binds to `0.0.0.0` **inside the container** so Docker bridge port publishing can reach it.
- The entrypoint resolves and `exec`s T3's packaged native binary rather than its npm launcher, so the server is PID 1 and receives `SIGTERM` and `SIGINT` directly.
- The built-in health check probes `http://127.0.0.1:${T3_PORT}/` from inside the container.

## Package layout and provider self-updates

The image separates code it ships from code the application maintains:

| Location | Owner | Contents | Updated by |
| --- | --- | --- | --- |
| `/usr/local/lib/node_modules/t3` | `root` | T3 Code itself | A new image, through the Unraid Docker template |
| `/opt/t3-providers` | `10000:10000` | Codex CLI, OpenCode CLI | T3's **Update** button, or a new image |

`/opt/t3-providers` is reached through root-owned symlinks in `/usr/local/bin` (`codex`, `opencode`), so the providers are on `PATH` while the writable prefix itself is **not**. That matters: the Unraid Tailscale hook runs as root with this image's environment, so putting a directory the application can write on `PATH` would let it shadow a binary that root executes. Its `/bin` holds the usual npm shims. T3 identifies a provider's install prefix by matching `/lib/node_modules/<package>/` inside the resolved real path of the provider binary, so this layout is detected as an npm-global install that T3 is allowed to update. It then runs `npm install -g --prefix /opt/t3-providers <package>@latest`, which writes both the package and its shim inside that prefix.

T3 itself stays root-owned and is intentionally **not** self-updatable: `t3 update` and the provider mechanism both write to a global prefix, and letting the running application replace its own binaries would silently diverge the container from its pinned versions. Ship T3 changes as an image bump.

Two root-owned paths are worth knowing about when diagnosing a failed update, because they fail differently:

- A root-owned `~/.npm` cache reports `npm error Your cache folder contains root-owned files`.
- A root-owned install prefix reports `EACCES` on `mkdir`, which surfaces in the T3 UI as **"Update command exited with code 243."** `243` is `256 - 13`, i.e. `EACCES` masked to the low 8 bits — not a T3-specific code.

The runtime paths are explicit:

| Variable | Path/value |
| --- | --- |
| `HOME` | `/home/t3` |
| `XDG_CONFIG_HOME` | `/home/t3/.config` |
| `XDG_CACHE_HOME` | `/home/t3/.cache` |
| `XDG_DATA_HOME` | `/home/t3/.local/share` |
| `XDG_STATE_HOME` | `/home/t3/.local/state` |
| `T3CODE_HOME` | `/home/t3/.local/share/t3-code` |
| `T3_PORT` | `9877` by default |

Any host bind directories that T3 must write need to be writable by UID/GID `10000:10000`. For this Unraid host, use the persistent paths `/mnt/user/appdata/hermes-agent-sandy/t3-code-home` → `/home/t3` and `/mnt/user/appdata/hermes-agent-sandy/t3-code-workspace` → `/workspace`; inside the Hermes container these are `/opt/data/t3-code-home` and `/opt/data/t3-code-workspace`.

## Persistent-home tool updates

Some tools audited alongside this image live in the **persistent home**, not in the image. They are deliberately not pinned or installed by this build context, and their updates are **not** applied by this workflow:

| Tool | Authority |
| --- | --- |
| pnpm 9 | persistent home (`$HOME/.local`), applied by the coordinator after review |
| uv | persistent home, applied by the coordinator after review |
| managed Python 3.12 | persistent home, managed through uv |
| Tailscale | installed and owned by the Unraid native Docker hook, never by this image or this repository |

Do not add image pins for these tools, install a local Ollama server, or mutate shared host plugins. Only the coordinator applies persistent-home updates, after review, within the persistent home environment as UID/GID `10000:10000`. The `npm` used below is the one bundled with Node 24 in this image, which is compatible with these commands.

Run these commands only in the persistent-home environment after review. First confirm the effective user and that `$HOME/.local` and its existing `bin` directory are user-owned; stop on a mismatch rather than changing ownership as root:

```sh
test "$(id -u):$(id -g)" = 10000:10000
test "$(stat -c '%u:%g' "$HOME/.local")" = 10000:10000
if [ -e "$HOME/.local/bin" ]; then
    test "$(stat -c '%u:%g' "$HOME/.local/bin")" = 10000:10000
fi
```

Install the current pnpm 9 line into the user-owned prefix, then verify it:

```sh
npm install --global --prefix "$HOME/.local" 'pnpm@9'
"$HOME/.local/bin/pnpm" --version
```

Confirm uv's installation provenance and the ownership of its resolved executable (`command -v uv` and `stat -Lc '%u:%g' "$(command -v uv)"`). For a **standalone user-owned** uv installation, update it in place and verify:

```sh
uv self update 0.13.1
uv --version
```

`uv self update` only applies to uv's own standalone installer. For a confirmed user-owned pipx installation, use `pipx install --force 'uv==0.13.1'`; for a confirmed user-site pip installation, use that installation's Python with `python3 -m pip install --user --upgrade 'uv==0.13.1'`, then run `uv --version` and check it reports `0.13.1`. Do not use these alternatives for an unknown or system-owned installation. Keep project package-manager pins, lockfiles, and virtual environments intact.

The supplied 2026-10-14 release evidence records **3.12.15** as the latest supported Python 3.12 patch. Availability through the selected **uv 0.13.1** is still unverified: the offline implementation environment has uv 0.12.13, whose built-in catalog lists 3.12.14. Before applying the Python update, the coordinator must confirm that uv 0.13.1 lists CPython 3.12.15 as its newest 3.12 download:

```sh
uv --version
uv python list 3.12 --only-downloads
```

After that verification, install and select the exact evidence-backed patch, then check the interpreter directly, outside any project environment:

```sh
uv python install 3.12.15
python312="$(uv python find --managed-python 3.12.15)"
"$python312" -c 'import sys; assert sys.version_info[:3] == (3, 12, 15), sys.version; print(sys.version)'
```

If the catalog disagrees, stop and review the evidence; do not silently substitute a patch. These instructions are pending that compatibility verification. Select the returned interpreter path explicitly where needed; do not recreate existing virtual environments or rewrite their Python selection as part of this image refresh. Retain Node 24's bundled compatible npm.

## Private Unraid Tailscale access

Use the **Use Tailscale** toggle in the Unraid Docker template. It creates a dedicated private tailnet identity for this container and runs the Unraid Tailscale hook before the image entrypoint.

- Keep Docker networking as `bridge`; do not publish a normal host port.
- Set **Tailscale State Directory** to `/home/t3/.tailscale_state`, which persists through the `/home/t3` bind mount.
- Enable Tailscale **Serve** for container port `9877`; keep **Funnel** and **Tailscale SSH** off.
- Do not mount a host Docker or Tailscale socket into the container.

Do **not** give this container:

- `/var/run/docker.sock` or another Docker/build API
- privileged mode
- host networking
- a Tailscale socket

Authentication state is provisioned interactively at runtime and must never be baked into this build context or image. GitHub credentials belong in `/home/t3/.config/gh`; OpenCode’s Ollama Cloud connection belongs in `/home/t3/.config/opencode`; both reside on the persistent home mount.

## Local static validation

Run the public release-gate regression tests without Docker or network access:

```sh
bash tests/image-smoke.sh --self-test
```

They execute the workflow's inspection and promotion shell blocks against synthetic Buildx responses, including separate provenance/SBOM manifests, reordered descriptors, lost/added/duplicated/changed descriptors, and promotion/inspection errors. They also assert that the smoke step bound-pulls the exact candidate digest before the smoke script runs and that a failed pull fails the step, and that the smoke's readiness status range stays identical to `healthcheck.sh`. They do not build an image or move a real tag.

Without building an image, the shell files can be syntax-checked read-only:

```sh
sh -n /opt/data/t3-code-unraid/entrypoint.sh
sh -n /opt/data/t3-code-unraid/healthcheck.sh
```

An end-to-end validation still requires a Docker-capable Unraid host or CI runner.

## CI build and Docker upgrade path

This build context includes `.github/workflows/build-ghcr.yml`, a pinned-action GitHub Actions workflow that builds the image with Buildx on pushes to `main` (or a manual run), publishes an OCI image to GitHub Container Registry, and records the immutable digest. The build always pulls the current base image and bypasses layer cache so Debian package indexes and installed packages are refreshed. It does not require a Docker socket on Hermes or Unraid.

To use this route, create a **private** GitHub repository containing this directory as its repository root, push `main`, and approve GitHub authentication from the interactive device flow when prompted. The workflow uses its short-lived `GITHUB_TOKEN`; no registry password is stored in this repository. Once the first image is published, set package visibility/permissions so the Unraid Docker daemon can pull it, then deploy by the digest through the separately approved UnraidClaw create operation.

### Candidate build, smoke, promotion, and verification

The workflow never publishes `stable` directly from the build step. Instead it:

1. Builds and pushes only the immutable candidate tag `sha-<commit>` (with `pull: true`, `no-cache: true`, `provenance: mode=max`, and `sbom: true`).
2. Inspects the candidate index by the digest returned from the build step and records every descriptor. It requires the expected `linux/amd64` image manifest plus provenance/SBOM attestation descriptors, then records the selected amd64 manifest's configuration digest.
3. Bound-pulls the exact candidate digest with `timeout 600 docker pull` and only then runs `bash tests/image-smoke.sh` against `ghcr.io/<owner>/t3-code-unraid@<candidate-index-digest>`, requiring the smoke container's image ID to equal the inspected amd64 configuration digest. Pulling first keeps a cold registry pull out of the smoke's per-call Docker budget; the smoke starts its container with `--pull=never` against that local copy. The smoke test launches the default entrypoint with disposable home/workspace volumes, no credentials, and networking disabled on `--platform linux/amd64`. It requires an HTTP status below 500 (mirroring `healthcheck.sh`, which accepts 200-499 with redirect handling disabled) within an elapsed-time deadline, native T3 as PID 1 running as `10000:10000`, app-writable provider directories, protected T3/launch paths and PATH directories, and real provider CLI and T3 launcher execution as the app user. Each Docker call is bounded. Normal SIGTERM must stop the container within a deadline with exit 0 or 143, without SIGKILL or OOM termination. Cleanup removes the container and its anonymous volumes; failures print logs and container state.
4. Promotes the complete candidate index to `stable` with a single `docker buildx imagetools create --tag ...:stable <candidate>@<digest>` call that carries the image manifest and attestations together. No rebuild or leaf-image pull/tag/push is used.
5. Re-inspects `stable` and requires an exact, order-independent descriptor multiset match (digests, media types, sizes, platforms, and attestation annotations, including all `unknown/unknown` descriptors) with the recorded candidate descriptors. Both the candidate and promoted index digests are reported to the step summary.

Every candidate build publishes `sha-<commit>` as an immutable rollback/deployment reference. `stable` is the tested update channel for the Unraid Docker template.

**Failure semantics.** Any failure before the promotion command (build, inspection, or smoke) prevents promotion and leaves `stable` unchanged. Promotion is the release mutation boundary: if promotion itself errors, or if the post-promotion inspection/comparison fails, the job fails and `stable` may already have moved. That outcome does not imply a rollback or an unchanged channel and requires coordinator investigation and any restoration using the preserved `sha-<commit>` rollback references; the workflow performs no automatic rollback.

Set the Unraid template repository to `ghcr.io/noamleibovitch/t3-code-unraid:stable`. The Docker tab's **Check for Updates** and **Update** actions can then pull a new image after a reviewed source change lands on `main`; the template, persistent mounts, and native Tailscale settings remain in place. Before updating, record the current `sha-<commit>` tag so it remains an explicit rollback target. Do not use `latest`.

The generated image is `linux/amd64`; verify Unraid CPU architecture during preflight before publishing or add a separately tested multi-architecture build.
