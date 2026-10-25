# T3 Code container build context for Unraid

This directory is a local Docker build context for a headless T3 Code server. It does not contain credentials. On Unraid 7+, the Docker template's native Tailscale integration owns private HTTPS access.

## Build boundary

**Build this image on a Docker-capable host or in CI.** The GitHub Actions workflow is the preferred publication path and does not require a Docker socket on Hermes or Unraid.

Example build on a Docker-capable host:

```sh
docker build --pull --no-cache --tag t3-code-unraid:0.1.2 /opt/data/t3-code-unraid
```

No remote `latest` tag is used. The direct tool versions are pinned as follows:

| Component | Pinned version/source |
| --- | --- |
| Node.js | `node:24.22.1-bookworm-slim` (Node 24 LTS with bundled npm `11.19.1`) |
| T3 Code (`t3`) | `0.1.2` official standalone `linux-x64`/`linux-arm64` archive |
| Codex CLI (`@openai/codex`) | `0.164.0` |
| OpenCode CLI (`opencode-ai`) | `1.19.4` |
| GitHub CLI (`gh`) | `2.103.2` |
| Ollama Cloud client (`ollama`) | `0.40.11` |

Both build stages pin the same Node `24.22.1` LTS base with bundled npm
`11.19.1`; the major line does not move to Node 26 or standalone npm 12.
Building with `--pull`/`no-cache` (as the CI workflow does) also refreshes the
Debian security packages. Those refreshed packages are installed and exercised
only by the CI image build, not by the offline checks in this source session.

T3 `0.1.2` no longer ships `@t3code/t3-platform` optional packages. Its npm
launcher (`bin/t3.mjs`) would download a mutable standalone tree into writable
`T3CODE_HOME` on first start, which this image deliberately avoids. The build
instead downloads the complete official release archive, verifies its SHA-256,
and extracts the full tree root-owned at `/opt/t3`: the native `t3` executable
plus `node_modules/`, `client/`, and `resource-monitor/`. All of those
companions are required and preserved. `/usr/local/bin/t3` is a root-owned
symlink to `/opt/t3/t3`, and the entrypoint executes `/opt/t3/t3` directly as
PID 1. There is no npm T3 package and no `@t3code` resolution in the image.
Version pins and the exact installed version plus required `serve` flags are
asserted at build time, so a mismatch or incomplete archive fails the build.

Archive names and SHA-256 values are selected for Debian `amd64` or `arm64`:

| T3 archive | SHA-256 |
| --- | --- |
| `t3-0.1.2-linux-x64.tar.gz` | `7aed625cb961938df174c1a067c0f05235360940b53e882a1643126b754da16c` |
| `t3-0.1.2-linux-arm64.tar.gz` | `df112e1f19772b4055a28c97b032eb6d038d5d7182015f1cafd3254ad6fabd0f` |

| GitHub CLI archive | SHA-256 |
| --- | --- |
| `gh_2.103.2_linux_amd64.tar.gz` | `62ccf747115ddc61237efffdde66a3c8f70ba249433dc64f70801089b59c59c8` |
| `gh_2.103.2_linux_arm64.tar.gz` | `4c3e99a50bd8b181a3fe9d69b25dd978bac768148d88f01507c6b4d1ef61a443` |

| Ollama archive | SHA-256 |
| --- | --- |
| `ollama-linux-amd64.tar.zst` | `7bedab90dd122661be78798e9f0edf37fccf0cccf2699d2c58ea1a3afdc04b6d` |
| `ollama-linux-arm64.tar.zst` | `77b278837b9e62c172f77d703675be4c52c8054e9075639031a9a6d5a53f1924` |

The GitHub CLI archive is `tar.gz`; Ollama archives are `tar.zst` and only
`bin/ollama` is extracted. CI downloads and checks every archive's bytes during
the image build, and the Dockerfile fails closed on a download or checksum
error. The final image contains only the Ollama client binary: it does not run
a local Ollama server, include model storage, or require a GPU.

The refresh uses the supplied release evidence dated 2026-10-25
(`.workflow-kit/release-evidence.json`, `.workflow-kit/CLI-COMPATIBILITY.json`,
and `.workflow-kit/base-image-verification.json`). This source stage performed
no downloads, image build, or Docker run. Separately, the parent downloaded and
SHA-256-verified the complete T3 `0.1.2` `linux-x64` archive and actually ran
`--version`, `serve --help`, an isolated HTTP startup (HTTP 200), and SIGTERM
(exit 130). That is limited artifact qualification, **not** image acceptance:
real image qualification remains required in CI. CI builds `amd64` only, so the
arm64 checksums are verified but no arm64 image build or runtime has been
validated; do not claim arm64 support without separate image verification.

## Runtime contract

- The Unraid Tailscale hook starts as root because it must initialize Tailscale. The image entrypoint then immediately drops privileges and runs T3 as `t3` (UID/GID `10000:10000`, matching the `hermes` appdata owner on this Unraid host).
- The root phase of the entrypoint deliberately resets `PATH` before `exec gosu`. The image ships no user-writable directory on `PATH`, and the reset keeps it that way even if a caller passes one in the environment. Without it, anything able to write to such a directory could shadow a binary that the root context executes. Do not remove that reset.
- `/workspace` is the expected project bind mount and the container working directory.
- `T3_PORT` controls both the T3 listener and the health check; its default is `9877`.
- T3 binds to `0.0.0.0` **inside the container** so Docker bridge port publishing can reach it.
- The entrypoint `exec`s `/opt/t3/t3` directly rather than the npm launcher, so the server is PID 1 and receives `SIGTERM` and `SIGINT` directly.
- The built-in health check probes `http://127.0.0.1:${T3_PORT}/` from inside the container.

## Package layout and provider self-updates

The image separates code it ships from code the application maintains:

| Location | Owner | Contents | Updated by |
| --- | --- | --- | --- |
| `/opt/t3` | `root` | Complete T3 Code standalone tree (`t3`, `node_modules/`, `client/`, `resource-monitor/`) | A new image, through the Unraid Docker template |
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

Some tools audited alongside this image live in the **persistent home**, not in the image. They are deliberately **not** image pins, and this source stage does not install or update them:

| Tool | Boundary |
| --- | --- |
| pnpm | Parent-owned persistent-home update to `12.15.0`, performed only while T3 is idle after provenance and ownership verification |
| uv | Parent-owned persistent-home update to `0.13.5`, performed only while T3 is idle after provenance and ownership verification |
| ripgrep (`rg`) | Retained at `15.2.0`; no image pin and no update in this stage |
| Corepack | Retained at `0.36.0`; do not replace it with an unreviewed shim operation |
| managed Python 3.12 | Baseline remains `3.12.15`. Python `3.12.16` was released 2026-10-25, but managed-binary availability and target-runtime qualification remain pending |
| Tailscale | Installed and owned by the Unraid native Docker hook, never by this image or this repository |

Do not add image pins for these tools, install a local Ollama server, mutate shared host plugins, or change the Python branch. For Python `3.12.16`, do not describe `3.12.15` as the latest patch and do not invent an installer or download method; availability must be established before any parent-owned update.

The parent owns persistent-home updates and must verify provenance and ownership under UID/GID `10000:10000` before applying them. Keep project package-manager pins, lockfiles, virtual environments, and the older tool versions available for rollback. Retain Node 24's bundled compatible npm; do not adopt Node 26 or standalone npm 12 here.

## T3 V2 generation and automatic migrations

T3 `0.1.2` stays on the **existing V2 generation**. This update does not introduce a new database generation and does not change the V2 data model beyond automatic migrations. The owner has approved the migration and will update connected apps.

On first start of `0.1.2` against an existing V2 database, T3 runs migrations `063` through `067` automatically:

- `063` drops obsolete V1 projection tables **only inside the current V2 database**. It does not alter the legacy `userdata/state.sqlite`.
- `064` canonicalizes thread pull-request links in V2 projection payloads and source events.
- `065` adds the Codex native-turn usage index.
- `066` repairs historical client settlement timestamps.
- `067` adds scheduled webhook deduplication and replay state.

Before the first `0.1.2` start, the parent must retain a quiesced snapshot of the current V2 database (`userdata/statev2.sqlite`) as the rollback reference, taken while T3 is idle. The schema is **not assumed to be downgrade-safe**: rolling back to a previous image requires restoring the matching quiesced snapshot rather than expecting reverse migrations.

**Never create, replace, or overwrite an existing `statev2.sqlite`.** A manual copy of `state.sqlite` after V2 has started would overwrite V2 progress. Preserve the legacy `userdata/state.sqlite` unchanged as rollback evidence. Do **not** run `t3 doctor cleanup`; later T3 releases can delete the pre-`0.1.0` database, which must remain.

Accounts, scopes, data, settings, provider credentials, and project work are retained; they live in the persistent home and workspace, not in the image. Native provider sessions, tool history, and checkpoint history are not part of the V1-to-V2 migration. Connected V1 apps remain incompatible with V2 and require app `2.0` or a matching web app. OpenCode 1 (`1.19.4`) is retained intentionally; there is no OpenCode 2 / `@opencode/cli` migration, no Node 26/npm 12 adoption, no host plugin change, and no public ingress in this update.

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

They execute the workflow's inspection and promotion shell blocks against synthetic Buildx responses, including separate provenance/SBOM manifests, reordered descriptors, lost/added/duplicated/changed descriptors, and promotion/inspection errors. They also assert that the smoke step bound-pulls the exact candidate digest before the smoke script runs and that a failed pull fails the step, and that the smoke's readiness status range stays identical to `healthcheck.sh`. A fake `docker` also drives the real smoke script through bounded shutdown fixtures: a post-SIGTERM exit `130` (the pinned Effect interruption code) is accepted, while a premature self-exit `130` before the signal and a forced SIGKILL (`exit 137`) are rejected, and a slow start that outlives the readiness deadline but is still running is not misreported as a premature exit. They additionally check the offline standalone-packaging contract: both Node base pins, every version ARG, the T3 archive extraction into `/opt/t3`, the root-owned launcher symlink, and the absence of npm T3/`@t3code` resolution. They do not build an image or move a real tag.

Without building an image, the shell files can be syntax-checked read-only:

```sh
sh -n entrypoint.sh
sh -n healthcheck.sh
```

An end-to-end validation still requires a Docker-capable Unraid host or CI runner.

## CI build and Docker upgrade path

This build context includes `.github/workflows/build-ghcr.yml`, a pinned-action GitHub Actions workflow that builds the image with Buildx on pushes to `main` (or a manual run), publishes an OCI image to GitHub Container Registry, and records the immutable digest. The build always pulls the current base image and bypasses layer cache so Debian package indexes and installed packages are refreshed. It does not require a Docker socket on Hermes or Unraid.

To use this route, create a **private** GitHub repository containing this directory as its repository root, push `main`, and approve GitHub authentication from the interactive device flow when prompted. The workflow uses its short-lived `GITHUB_TOKEN`; no registry password is stored in this repository. Once the first image is published, set package visibility/permissions so the Unraid Docker daemon can pull it, then deploy by the digest through the separately approved UnraidClaw create operation.

### Candidate build, smoke, promotion, and verification

The workflow never publishes `stable` directly from the build step. Instead it:

1. Builds and pushes only the immutable candidate tag `sha-<commit>` (with `pull: true`, `no-cache: true`, `provenance: mode=max`, and `sbom: true`).
2. Inspects the candidate index by the digest returned from the build step and records every descriptor. It requires the expected `linux/amd64` image manifest plus provenance/SBOM attestation descriptors, then records the selected amd64 manifest's configuration digest.
3. Bound-pulls the exact candidate digest with `timeout 600 docker pull` and only then runs `bash tests/image-smoke.sh` against `ghcr.io/<owner>/t3-code-unraid@<candidate-index-digest>`, requiring the smoke container's image ID to equal the inspected amd64 configuration digest. Pulling first keeps a cold registry pull out of the smoke's per-call Docker budget; the smoke starts its container with `--pull=never` against that local copy. The smoke test launches the default entrypoint with disposable home/workspace volumes, no credentials, and networking disabled on `--platform linux/amd64`. It requires an HTTP status below 500 (mirroring `healthcheck.sh`, which accepts 200-499 with redirect handling disabled) within an elapsed-time deadline; `/opt/t3/t3` as PID 1 running as `10000:10000`; the complete standalone `t3`/`node_modules`/`client`/`resource-monitor` tree and protected T3/launch paths root-owned and not app-writable; app-writable provider directories; and real provider CLI and T3 launcher execution as the app user. Each Docker call is bounded. It verifies the container is still running immediately before the signal, then requires normal SIGTERM to stop it within a deadline with exit `0`, `130`, or `143`, without SIGKILL or OOM termination; any other code, and any pre-signal self-exit, fails. Exit `130` is expected here rather than a bug: the pinned Effect `4.0.0-rc.115` registers `SIGTERM` alongside `SIGINT` to trigger an interruption, and its `defaultTeardown` returns `130` for an interrupt-only cause. Exit `143` covers a plain raw-SIGTERM termination and `0` a clean shutdown. Cleanup removes the container and its anonymous volumes; failures print logs and container state.
4. Promotes the complete candidate index to `stable` with a single `docker buildx imagetools create --tag ...:stable <candidate>@<digest>` call that carries the image manifest and attestations together. No rebuild or leaf-image pull/tag/push is used.
5. Re-inspects `stable` and requires an exact, order-independent descriptor multiset match (digests, media types, sizes, platforms, and attestation annotations, including all `unknown/unknown` descriptors) with the recorded candidate descriptors. Both the candidate and promoted index digests are reported to the step summary.

Every candidate build publishes `sha-<commit>` as an immutable rollback/deployment reference. `stable` is the tested update channel for the Unraid Docker template.

**Failure semantics.** Any failure before the promotion command (build, inspection, or smoke) prevents promotion and leaves `stable` unchanged. Promotion is the release mutation boundary: if promotion itself errors, or if the post-promotion inspection/comparison fails, the job fails and `stable` may already have moved. That outcome does not imply a rollback or an unchanged channel and requires coordinator investigation and any restoration using the preserved `sha-<commit>` rollback references; the workflow performs no automatic rollback.

Set the Unraid template repository to `ghcr.io/noamleibovitch/t3-code-unraid:stable`. The Docker tab's **Check for Updates** and **Update** actions can then pull a new image after a reviewed source change lands on `main`; the template, persistent mounts, and native Tailscale settings remain in place. Before updating, record the current `sha-<commit>` tag so it remains an explicit rollback target. Do not use `latest`.

The generated image is `linux/amd64`; verify Unraid CPU architecture during preflight before publishing or add a separately tested multi-architecture build.
