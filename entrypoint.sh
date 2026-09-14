#!/bin/sh
set -eu

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
    --cwd /workspace \
    --no-browser \
    "$@"
