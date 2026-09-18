#!/bin/sh
set -eu

# Unraid's Docker Tailscale integration replaces the image entrypoint with a
# hook that installs and starts Tailscale. That hook requires UID 0. Once it
# has handed control back to this entrypoint, immediately run the application
# as the dedicated unprivileged account.
if [ "$(id -u)" -eq 0 ]; then
    # Resolve gosu before hardening so the binary path is not PATH-dependent.
    gosu_bin="$(command -v gosu)"
    # Harden the root phase: /opt/t3-providers/bin is intentionally writable by
    # the application user (so T3's in-UI provider updates work) and must never
    # be able to shadow a binary that this root context executes.
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    exec "${gosu_bin}" t3:t3 /usr/local/bin/t3-entrypoint "$@"
fi

T3_PORT="${T3_PORT:-9877}"

case "${T3_PORT}" in
    ''|*[!0-9]*)
        echo "T3_PORT must be an integer from 1 through 65535; got: ${T3_PORT}" >&2
        exit 64
        ;;
esac

if [ "${T3_PORT}" -lt 1 ] || [ "${T3_PORT}" -gt 65535 ]; then
    echo "T3_PORT must be an integer from 1 through 65535; got: ${T3_PORT}" >&2
    exit 64
fi

case "${T3CODE_TAILSCALE_SERVE:-false}" in
    1|true|TRUE|yes|YES|on|ON)
        echo "Tailscale Serve is host-owned and cannot be enabled inside this container." >&2
        exit 64
        ;;
esac

for argument in "$@"; do
    case "${argument}" in
        --tailscale-serve|--tailscale-serve=*|--tailscale-serve-port|--tailscale-serve-port=*)
            echo "${argument} is not allowed: Tailscale Serve must remain on the Unraid host." >&2
            exit 64
            ;;
    esac
done

# Ignore inert Tailscale configuration so only the host can own routing.
unset T3CODE_TAILSCALE_SERVE T3CODE_TAILSCALE_SERVE_PORT

mkdir -p \
    "${XDG_CONFIG_HOME}" \
    "${XDG_CACHE_HOME}" \
    "${XDG_DATA_HOME}" \
    "${XDG_STATE_HOME}" \
    "${T3CODE_HOME}"

# exec makes T3 PID 1 so SIGTERM/SIGINT reach it directly.
exec t3 serve \
    --host 0.0.0.0 \
    --port "${T3_PORT}" \
    --base-dir "${T3CODE_HOME}" \
    --no-browser \
    "$@" \
    /workspace
