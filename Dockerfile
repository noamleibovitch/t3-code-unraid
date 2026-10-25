# syntax=docker/dockerfile:1

FROM node:24.22.1-bookworm-slim AS toolchain

ARG T3_VERSION=0.1.2
ARG CODEX_VERSION=0.164.0
ARG OPENCODE_VERSION=1.19.4
ARG GH_VERSION=2.103.2
ARG OLLAMA_VERSION=0.40.11

# Providers (codex, opencode) live in a dedicated prefix owned by the
# application user so T3's in-UI provider updates can run. T3 itself stays in
# the root-owned /opt/t3 standalone tree: the running application must not
# replace itself, and image updates ship through the Docker template.
ARG PROVIDER_PREFIX=/opt/t3-providers

ENV NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        python3 \
        zstd; \
    rm -rf /var/lib/apt/lists/*; \
    npm install --global --omit=dev --prefix "${PROVIDER_PREFIX}" \
        --allow-scripts=@openai/codex \
        --allow-scripts=opencode-ai \
        "@openai/codex@${CODEX_VERSION}" \
        "opencode-ai@${OPENCODE_VERSION}"; \
    node -e "const prefix=process.argv[1]; const expected=[[prefix+'/lib/node_modules/@openai/codex/package.json',process.argv[2]],[prefix+'/lib/node_modules/opencode-ai/package.json',process.argv[3]]]; for (const [file,want] of expected) { const got=require(file).version; if (got !== want) throw new Error(file + ': expected ' + want + ', got ' + got); }" \
        "${PROVIDER_PREFIX}" "${CODEX_VERSION}" "${OPENCODE_VERSION}"; \
    npm cache clean --force

# T3 0.1.2 no longer ships @t3code platform packages. Its npm launcher would
# download a standalone tree into writable T3CODE_HOME on first run, so install
# the complete official release archive here instead. Keep the full tree
# (t3, node_modules/, client/, resource-monitor/) root-owned and immutable; the
# runtime entrypoint executes /opt/t3/t3 directly as PID 1.
RUN set -eux; \
    architecture="$(dpkg --print-architecture)"; \
    case "${architecture}" in \
        amd64) t3_arch=x64; t3_sha256=7aed625cb961938df174c1a067c0f05235360940b53e882a1643126b754da16c ;; \
        arm64) t3_arch=arm64; t3_sha256=df112e1f19772b4055a28c97b032eb6d038d5d7182015f1cafd3254ad6fabd0f ;; \
        *) echo "Unsupported architecture for T3 Code: ${architecture}" >&2; exit 1 ;; \
    esac; \
    archive="t3-${T3_VERSION}-linux-${t3_arch}.tar.gz"; \
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        "https://github.com/pingdotgg/t3code/releases/download/v${T3_VERSION}/${archive}" \
        --output "/tmp/${archive}"; \
    printf '%s  %s\n' "${t3_sha256}" "/tmp/${archive}" | sha256sum --check --strict -; \
    mkdir -p /opt/t3; \
    tar -xzf "/tmp/${archive}" -C /opt/t3 --strip-components=1; \
    chown -R 0:0 /opt/t3; \
    test -x /opt/t3/t3; \
    test -d /opt/t3/node_modules; \
    test -d /opt/t3/client; \
    test -d /opt/t3/resource-monitor; \
    /opt/t3/t3 --version; \
    rm -f "/tmp/${archive}"

RUN set -eux; \
    architecture="$(dpkg --print-architecture)"; \
    case "${architecture}" in \
        amd64) gh_arch=amd64; gh_sha256=62ccf747115ddc61237efffdde66a3c8f70ba249433dc64f70801089b59c59c8 ;; \
        arm64) gh_arch=arm64; gh_sha256=4c3e99a50bd8b181a3fe9d69b25dd978bac768148d88f01507c6b4d1ef61a443 ;; \
        *) echo "Unsupported architecture for GitHub CLI: ${architecture}" >&2; exit 1 ;; \
    esac; \
    archive="gh_${GH_VERSION}_linux_${gh_arch}.tar.gz"; \
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${archive}" \
        --output "/tmp/${archive}"; \
    printf '%s  %s\n' "${gh_sha256}" "/tmp/${archive}" | sha256sum --check --strict -; \
    tar -xzf "/tmp/${archive}" -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh; \
    gh version; \
    rm -rf "/tmp/${archive}" "/tmp/gh_${GH_VERSION}_linux_${gh_arch}"

# The CLI supports direct Ollama Cloud discovery. No local Ollama server,
# GPU runtime, or model storage is included in the final image.
RUN set -eux; \
    architecture="$(dpkg --print-architecture)"; \
    case "${architecture}" in \
        amd64) ollama_arch=amd64; ollama_sha256=7bedab90dd122661be78798e9f0edf37fccf0cccf2699d2c58ea1a3afdc04b6d ;; \
        arm64) ollama_arch=arm64; ollama_sha256=77b278837b9e62c172f77d703675be4c52c8054e9075639031a9a6d5a53f1924 ;; \
        *) echo "Unsupported architecture for Ollama CLI: ${architecture}" >&2; exit 1 ;; \
    esac; \
    archive="ollama-linux-${ollama_arch}.tar.zst"; \
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        "https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/${archive}" \
        --output "/tmp/${archive}"; \
    printf '%s  %s\n' "${ollama_sha256}" "/tmp/${archive}" | sha256sum --check --strict -; \
    mkdir -p /opt/ollama; \
    tar --use-compress-program=unzstd -xf "/tmp/${archive}" -C /opt/ollama bin/ollama; \
    /opt/ollama/bin/ollama --version; \
    rm -f "/tmp/${archive}"

FROM node:24.22.1-bookworm-slim AS runtime

ARG T3_VERSION=0.1.2
ARG CODEX_VERSION=0.164.0
ARG OPENCODE_VERSION=1.19.4
ARG GH_VERSION=2.103.2
ARG OLLAMA_VERSION=0.40.11

# Must match the toolchain stage: this prefix is owned by the application user
# so T3's in-UI provider updates work, while T3 itself stays root-owned.
ARG PROVIDER_PREFIX=/opt/t3-providers

LABEL org.opencontainers.image.title="T3 Code for Unraid" \
      org.opencontainers.image.description="Tailscale-hook-compatible T3 Code server with a non-root application runtime" \
      org.opencontainers.image.version="${T3_VERSION}"

ENV HOME=/home/t3 \
    XDG_CONFIG_HOME=/home/t3/.config \
    XDG_CACHE_HOME=/home/t3/.cache \
    XDG_DATA_HOME=/home/t3/.local/share \
    XDG_STATE_HOME=/home/t3/.local/state \
    T3CODE_HOME=/home/t3/.local/share/t3-code \
    T3CODE_NO_BROWSER=true \
    T3_PORT=9877

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        git \
        gosu \
        libatomic1 \
        openssh-client; \
    rm -rf /var/lib/apt/lists/*; \
    groupmod --gid 10000 --new-name t3 node; \
    usermod --uid 10000 --login t3 --home /home/t3 --move-home --shell /bin/bash node; \
    mkdir -p \
        "${XDG_CONFIG_HOME}" \
        "${XDG_CACHE_HOME}" \
        "${XDG_DATA_HOME}" \
        "${XDG_STATE_HOME}" \
        "${T3CODE_HOME}" \
        /workspace; \
    chown -R t3:t3 /home/t3 /workspace

# The complete official T3 standalone tree stays root-owned in /opt/t3.
COPY --from=toolchain /opt/t3/ /opt/t3/
# Providers are copied with application-user ownership so T3 can update them in
# place from the UI. The writable prefix is deliberately NOT placed on PATH:
# the Unraid Tailscale hook runs as root with this image's environment, so a
# PATH entry the application can write would let it shadow a binary that root
# executes. Root-owned symlinks in /usr/local/bin point into the prefix instead.
COPY --from=toolchain --chown=10000:10000 /opt/t3-providers/ /opt/t3-providers/
COPY --from=toolchain /usr/local/bin/gh /usr/local/bin/gh
COPY --from=toolchain /opt/ollama/bin/ollama /usr/local/bin/ollama

RUN set -eux; \
    ln -s /opt/t3/t3 /usr/local/bin/t3; \
    ln -s "${PROVIDER_PREFIX}/bin/codex" /usr/local/bin/codex; \
    ln -s "${PROVIDER_PREFIX}/bin/opencode" /usr/local/bin/opencode; \
    node -e "const prefix=process.argv[1]; const expected=[[prefix+'/lib/node_modules/@openai/codex/package.json',process.argv[2]],[prefix+'/lib/node_modules/opencode-ai/package.json',process.argv[3]]]; for (const [file,want] of expected) { const got=require(file).version; if (got !== want) throw new Error(file + ': expected ' + want + ', got ' + got); }" \
        "${PROVIDER_PREFIX}" "${CODEX_VERSION}" "${OPENCODE_VERSION}"; \
    node -e "const fs=require('fs'); const st=fs.statSync(process.argv[1]); if (st.uid !== 10000 || st.gid !== 10000) throw new Error(process.argv[1] + ' must be owned by 10000:10000 for in-UI provider updates; got ' + st.uid + ':' + st.gid);" "${PROVIDER_PREFIX}/lib/node_modules"; \
    node -e "const out=require('node:child_process').execFileSync('gh',['version'],{encoding:'utf8'}); if (!out.startsWith('gh version ' + process.argv[1] + ' ')) throw new Error('unexpected gh version: ' + out);" "${GH_VERSION}"; \
    ollama --version | grep -F "${OLLAMA_VERSION}"

COPY entrypoint.sh /usr/local/bin/t3-entrypoint
COPY healthcheck.sh /usr/local/bin/t3-healthcheck
COPY check-runtime-deps.mjs /usr/local/bin/t3-check-runtime-deps

RUN chmod 0755 /usr/local/bin/t3-entrypoint /usr/local/bin/t3-healthcheck /usr/local/bin/t3-check-runtime-deps

# Fail the build if the pinned T3 native binary cannot start on this base image.
# A shared-library regression here otherwise ships a healthy-looking image whose
# container exits immediately (observed: missing libatomic.so.1 -> exit 127).
RUN /usr/local/bin/t3-check-runtime-deps

WORKDIR /workspace
VOLUME ["/workspace"]
EXPOSE 9877

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/usr/local/bin/t3-healthcheck"]

ENTRYPOINT ["/usr/local/bin/t3-entrypoint"]
