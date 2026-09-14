#!/bin/sh
set -eu

port="${T3_PORT:-9877}"

case "${port}" in
    ''|*[!0-9]*) exit 1 ;;
esac

if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    exit 1
fi

exec node -e '
const port = process.argv[1];
fetch("http://127.0.0.1:" + port + "/", {
  redirect: "manual",
  signal: AbortSignal.timeout(3000),
}).then((response) => {
  if (response.status >= 200 && response.status < 500) process.exit(0);
  console.error("T3 health check returned HTTP " + response.status);
  process.exit(1);
}).catch((error) => {
  console.error("T3 health check failed: " + error.message);
  process.exit(1);
});
' "${port}"
