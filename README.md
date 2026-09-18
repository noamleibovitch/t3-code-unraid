# T3 Code container build context for Unraid

This directory is a local Docker build context for a headless T3 Code server. It does not contain credentials. On Unraid 7+, the Docker template's native Tailscale integration owns private HTTPS access.

## Build boundary

**This image must be built on the Unraid host or in CI.** The agent that prepared these files has no Docker socket or documented image-build API, so it did not build an image or create a container.

Example build on a Docker-capable host:

```sh
docker build --tag t3-code-unraid:0.0.42 /opt/data/t3-code-unraid
```

No remote `latest` tag is used. The direct tool versions are pinned as follows:

| Component | Pinned version/source |
| --- | --- |
| Node.js | `node:22-bookworm-slim` family |
| T3 Code (`t3`) | `0.0.42` |
| Codex CLI (`@openai/codex`) | `0.155.0` |
| OpenCode CLI (`opencode-ai`) | `1.18.31` |
| GitHub CLI (`gh`) | `2.101.0` |
| Ollama Cloud client (`ollama`) | `0.34.2` |

From `t3` `0.0.41` onward the npm package ships a launcher at `bin/t3.js` and
resolves its platform binary from `@t3code/t3-<platform>-<arch>`. The image links
`/usr/local/bin/t3` to that launcher; the older `dist/bin.mjs` path still exists
but is no longer the declared entry point. Version pins are asserted in both
build stages, so a mismatch fails the image build instead of shipping silently.

The GitHub CLI and Ollama client archives are selected for Debian `amd64` or `arm64` and checked against release SHA-256 values before installation. The final image contains only the Ollama client binary: it does not run a local Ollama server, include model storage, or require a GPU.

## Runtime contract

- The Unraid Tailscale hook starts as root because it must initialize Tailscale. The image entrypoint then immediately drops privileges and runs T3 as `t3` (UID/GID `10000:10000`, matching the `hermes` appdata owner on this Unraid host).
- The root phase of the entrypoint deliberately resets `PATH` before `exec gosu`. The image ships no user-writable directory on `PATH`, and the reset keeps it that way even if a caller passes one in the environment. Without it, anything able to write to such a directory could shadow a binary that the root context executes. Do not remove that reset.
- `/workspace` is the expected project bind mount and the container working directory.
- `T3_PORT` controls both the T3 listener and the health check; its default is `9877`.
- T3 binds to `0.0.0.0` **inside the container** so Docker bridge port publishing can reach it.
- The entrypoint uses `exec`, so T3 receives `SIGTERM` and `SIGINT` directly.
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

Without building an image, the shell files can be syntax-checked read-only:

```sh
sh -n /opt/data/t3-code-unraid/entrypoint.sh
sh -n /opt/data/t3-code-unraid/healthcheck.sh
```

An end-to-end validation still requires a Docker-capable Unraid host or CI runner.

## CI build and Docker upgrade path

This build context includes `.github/workflows/build-ghcr.yml`, a pinned-action GitHub Actions workflow that builds the image with Buildx on pushes to `main` (or a manual run), publishes an OCI image to GitHub Container Registry, and records the immutable digest. It does not require a Docker socket on Hermes or Unraid.

To use this route, create a **private** GitHub repository containing this directory as its repository root, push `main`, and approve GitHub authentication from the interactive device flow when prompted. The workflow uses its short-lived `GITHUB_TOKEN`; no registry password is stored in this repository. Once the first image is published, set package visibility/permissions so the Unraid Docker daemon can pull it, then deploy by the digest through the separately approved UnraidClaw create operation.

Every successful build publishes both:

- `sha-<commit>` — immutable rollback/deployment reference.
- `stable` — the tested update channel for the Unraid Docker template.

Set the Unraid template repository to `ghcr.io/noamleibovitch/t3-code-unraid:stable`. The Docker tab's **Check for Updates** and **Update** actions can then pull a new image after a reviewed source change lands on `main`; the template, persistent mounts, and native Tailscale settings remain in place. Before updating, record the current `sha-<commit>` tag so it remains an explicit rollback target. Do not use `latest`.

The generated image is `linux/amd64`; verify Unraid CPU architecture during preflight before publishing or add a separately tested multi-architecture build.

