# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim AS toolchain

ARG T3_VERSION=0.0.42
ARG CODEX_VERSION=0.154.0
ARG OPENCODE_VERSION=1.18.31
ARG GH_VERSION=2.101.0
ARG OLLAMA_VERSION=0.34.1

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
    npm install --global --omit=dev \
        "t3@${T3_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "opencode-ai@${OPENCODE_VERSION}"; \
    node -e "const expected=[['/usr/local/lib/node_modules/t3/package.json',process.argv[1]],['/usr/local/lib/node_modules/@openai/codex/package.json',process.argv[2]],['/usr/local/lib/node_modules/opencode-ai/package.json',process.argv[3]]]; for (const [file,want] of expected) { const got=require(file).version; if (got !== want) throw new Error(file + ': expected ' + want + ', got ' + got); }" \
        "${T3_VERSION}" "${CODEX_VERSION}" "${OPENCODE_VERSION}"; \
    npm cache clean --force

RUN set -eux; \
    architecture="$(dpkg --print-architecture)"; \
    case "${architecture}" in \
        amd64) gh_arch=amd64; gh_sha256=9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8 ;; \
        arm64) gh_arch=arm64; gh_sha256=b57e8063f18862647c9d22727c32e9da1b963f8bf9db648fe123a6975695640f ;; \
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
        amd64) ollama_arch=amd64; ollama_sha256=f361dc3992ec07e4ad429f4bb2d10d4663ba2c295f9a9a688c7d52f4ba650034 ;; \
        arm64) ollama_arch=arm64; ollama_sha256=b4bdbbbf5faf2fc15f9f6d775c984a33d5c6fee7b4fdeb3fb56612e58a172db9 ;; \
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

FROM node:22-bookworm-slim AS runtime

ARG T3_VERSION=0.0.42
ARG CODEX_VERSION=0.154.0
ARG OPENCODE_VERSION=1.18.31
ARG GH_VERSION=2.101.0
ARG OLLAMA_VERSION=0.34.1

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

COPY --from=toolchain /usr/local/lib/node_modules/ /usr/local/lib/node_modules/
COPY --from=toolchain /usr/local/bin/gh /usr/local/bin/gh
COPY --from=toolchain /opt/ollama/bin/ollama /usr/local/bin/ollama

RUN set -eux; \
    ln -s ../lib/node_modules/t3/bin/t3.js /usr/local/bin/t3; \
    ln -s ../lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex; \
    ln -s ../lib/node_modules/opencode-ai/bin/opencode.exe /usr/local/bin/opencode; \
    node -e "const expected=[['/usr/local/lib/node_modules/t3/package.json',process.argv[1]],['/usr/local/lib/node_modules/@openai/codex/package.json',process.argv[2]],['/usr/local/lib/node_modules/opencode-ai/package.json',process.argv[3]]]; for (const [file,want] of expected) { const got=require(file).version; if (got !== want) throw new Error(file + ': expected ' + want + ', got ' + got); }" \
        "${T3_VERSION}" "${CODEX_VERSION}" "${OPENCODE_VERSION}"; \
    node -e "const out=require('node:child_process').execFileSync('gh',['version'],{encoding:'utf8'}); if (!out.startsWith('gh version ' + process.argv[1] + ' ')) throw new Error('unexpected gh version: ' + out);" "${GH_VERSION}"; \
    ollama --version | grep -F "${OLLAMA_VERSION}"

COPY entrypoint.sh /usr/local/bin/t3-entrypoint
COPY healthcheck.sh /usr/local/bin/t3-healthcheck

RUN chmod 0755 /usr/local/bin/t3-entrypoint /usr/local/bin/t3-healthcheck

WORKDIR /workspace
VOLUME ["/workspace"]
EXPOSE 9877

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/usr/local/bin/t3-healthcheck"]

ENTRYPOINT ["/usr/local/bin/t3-entrypoint"]
