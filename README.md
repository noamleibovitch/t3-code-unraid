# T3 Code container build context for Unraid

This directory is a local Docker build context for a headless T3 Code server. It does not contain credentials and does not configure Unraid, Docker networking, or Tailscale.

## Build boundary

**This image must be built on the Unraid host or in CI.** The agent that prepared these files has no Docker socket or documented image-build API, so it did not build an image or create a container.

Example build on a Docker-capable host:

```sh
docker build --tag t3-code-unraid:0.0.40 /opt/data/t3-code-unraid
```

No remote `latest` tag is used. The direct tool versions are pinned as follows:

| Component | Pinned version/source |
| --- | --- |
| Node.js | `node:22-bookworm-slim` family |
| T3 Code (`t3`) | `0.0.40` |
| Codex CLI (`@openai/codex`) | `0.154.0` |
| OpenCode CLI (`opencode-ai`) | `1.18.30` |
| GitHub CLI (`gh`) | `2.100.0` |

The GitHub CLI archive is selected for Debian `amd64` or `arm64` and checked against the release SHA-256 before installation. T3's native Node dependencies are compiled in a separate build stage; compiler packages are not copied into the runtime image.

## Runtime contract

- The process runs as the non-root `t3` user (UID/GID `10000:10000`, matching the `hermes` appdata owner on this Unraid host).
- `/workspace` is the expected project bind mount and the container working directory.
- `T3_PORT` controls both the T3 listener and the health check; its default is `9877`.
- T3 binds to `0.0.0.0` **inside the container** so Docker bridge port publishing can reach it.
- The entrypoint uses `exec`, so T3 receives `SIGTERM` and `SIGINT` directly.
- The built-in health check probes `http://127.0.0.1:${T3_PORT}/` from inside the container.

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

## Loopback-only host publication

Publish the container port only on the Unraid host's loopback interface:

```text
127.0.0.1:9877:9877
```

For a custom port, set `T3_PORT` and use the same container port in the mapping, for example `127.0.0.1:10087:10087` with `T3_PORT=10087`.

Host routing belongs to Unraid, not this image. Tailscale Serve must remain host-owned and should route to the loopback-published host port. The entrypoint rejects `--tailscale-serve` and `--tailscale-serve-port` and refuses an enabled `T3CODE_TAILSCALE_SERVE` value.

Do **not** give this container:

- `/var/run/docker.sock` or another Docker/build API
- privileged mode
- host networking
- a Tailscale socket

A bridge-mode runtime shape is:

```sh
docker run --rm \
  --name t3-code \
  --publish 127.0.0.1:9877:9877 \
  --env T3_PORT=9877 \
  --mount type=bind,src=/absolute/path/to/projects,dst=/workspace \
  --mount type=bind,src=/absolute/path/to/t3-home,dst=/home/t3 \
  t3-code-unraid:0.0.40
```

The command is documentation only; it was not executed here. Authentication state, if needed later, must be provisioned by the operator at runtime and must never be baked into this build context or image.

## Local static validation

Without building an image, the shell files can be syntax-checked read-only:

```sh
sh -n /opt/data/t3-code-unraid/entrypoint.sh
sh -n /opt/data/t3-code-unraid/healthcheck.sh
```

An end-to-end validation still requires a Docker-capable Unraid host or CI runner.

## Alternative build path: GitHub Actions → GHCR

This build context includes `.github/workflows/build-ghcr.yml`, a pinned-action GitHub Actions workflow that builds the image with Buildx on pushes to `main` (or a manual run), publishes an OCI image to GitHub Container Registry, and records the immutable digest. It does not require a Docker socket on Hermes or Unraid.

To use this route, create a **private** GitHub repository containing this directory as its repository root, push `main`, and approve GitHub authentication from the interactive device flow when prompted. The workflow uses its short-lived `GITHUB_TOKEN`; no registry password is stored in this repository. Once the first image is published, set package visibility/permissions so the Unraid Docker daemon can pull it, then deploy by the digest through the separately approved UnraidClaw create operation.

Do not deploy from mutable tags such as `latest`; record and use the workflow's `ghcr.io/<owner>/t3-code-unraid@sha256:…` digest. The generated image is `linux/amd64`; verify Unraid CPU architecture during preflight before publishing or add a separately tested multi-architecture build.

