#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_env

if [[ ! -f "${PID_FILE}" ]]; then
    die "No PID file found at ${PID_FILE}. Praxis may not be running."
fi

pid="$(cat "${PID_FILE}")"

if ! kill -0 "${pid}" 2>/dev/null; then
    info "PID ${pid} is not running. Cleaning up stale PID file."
    rm -f "${PID_FILE}"
    exit 0
fi

if ! pid_is_praxis "${pid}"; then
    die "PID ${pid} is not a Praxis process. Refusing to stop."
fi

info "Stopping Praxis (PID ${pid})"
kill -INT "${pid}"

for _ in $(seq 1 40); do
    if ! kill -0 "${pid}" 2>/dev/null; then
        rm -f "${PID_FILE}"
        ok "Praxis stopped"
        exit 0
    fi
    sleep 0.25
done

fail "Praxis did not exit within 10 seconds; sending SIGKILL"
kill -9 "${pid}" 2>/dev/null || true
rm -f "${PID_FILE}"
ok "Praxis killed"
