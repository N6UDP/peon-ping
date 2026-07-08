#!/bin/bash
# peon-ping: manage the optional pocket-tts "serve" daemon (macOS / Linux / WSL)
# used by tts-pockettts.sh for warm (~3s) synthesis. Without it the backend
# falls back to the ~7s `uvx pocket-tts generate` CLI.
#
# One shared daemon per port serves every agent session on the machine. Start is
# multi-session safe: a health check short-circuits when it's already up, and an
# atomic mkdir lock serialises the start window so concurrent sessions never
# spawn duplicate daemons.
#
# Port resolution: PEON_PTTS_PORT env, else config.json tts.pockettts.port, else 8123.
#
# Usage: pockettts-serve.sh {start|stop|status|restart}

set -uo pipefail

ACTION="${1:-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_JSON="$INSTALL_DIR/config.json"

_port() {
  if [ -n "${PEON_PTTS_PORT:-}" ]; then printf '%s' "$PEON_PTTS_PORT"; return; fi
  if [ -f "$CONFIG_JSON" ] && command -v python3 >/dev/null 2>&1; then
    local p
    p="$(python3 -c "
import json,sys
try:
    print((json.load(open(sys.argv[1])).get('tts',{}) or {}).get('pockettts',{}).get('port',8123))
except Exception:
    print(8123)
" "$CONFIG_JSON" 2>/dev/null)"
    [ -n "$p" ] && { printf '%s' "$p"; return; }
  fi
  printf '8123'
}

PORT="$(_port)"
BASE="http://localhost:$PORT"
TMP="${TMPDIR:-/tmp}"
PIDFILE="$TMP/pockettts-serve-$PORT.pid"
LOCKDIR="$TMP/pockettts-serve-$PORT.lock"

_up() { command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "$BASE/health" >/dev/null 2>&1; }

_wait_up() {
  local secs="$1" i=0
  while [ "$i" -lt "$secs" ]; do _up && return 0; sleep 1; i=$((i+1)); done
  return 1
}

_start() {
  if _up; then echo "pocket-tts serve already up on :$PORT"; return 0; fi

  # Steal a stale lock (>90s) left by a crashed starter.
  if [ -d "$LOCKDIR" ]; then
    local age now mtime
    now=$(date +%s)
    mtime=$(stat -f %m "$LOCKDIR" 2>/dev/null || stat -c %Y "$LOCKDIR" 2>/dev/null || echo "$now")
    age=$((now - mtime))
    [ "$age" -gt 90 ] && rmdir "$LOCKDIR" 2>/dev/null || true
  fi

  # mkdir is atomic — only one session wins the start window.
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "Another session is starting pocket-tts serve; waiting..."
    if _wait_up 60; then echo "pocket-tts serve up on :$PORT"; else echo "pocket-tts serve not ready after 60s" >&2; fi
    return 0
  fi

  # shellcheck disable=SC2064
  trap "rmdir '$LOCKDIR' 2>/dev/null || true" EXIT
  if _up; then echo "pocket-tts serve already up on :$PORT"; return 0; fi
  if ! command -v uvx >/dev/null 2>&1; then echo "uvx not found on PATH" >&2; return 0; fi

  nohup uvx pocket-tts serve --port "$PORT" >/dev/null 2>&1 &
  echo "$!" > "$PIDFILE"
  echo "Starting pocket-tts serve on :$PORT (pid $!); loading model..."
  if _wait_up 90; then echo "Ready on :$PORT"; else echo "Daemon started (pid $!) but /health not ready after 90s" >&2; fi
}

_stop() {
  if [ -f "$PIDFILE" ]; then
    local dpid; dpid="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
      kill "$dpid" 2>/dev/null && echo "Stopped pocket-tts serve on :$PORT (pid $dpid)"
    else
      echo "No running pocket-tts serve for :$PORT"
    fi
    rm -f "$PIDFILE"
  else
    echo "No tracked pocket-tts serve pid for :$PORT"
  fi
}

case "$ACTION" in
  start)   _start ;;
  stop)    _stop ;;
  restart) _stop; sleep 1; _start ;;
  status)
    if _up; then echo "pocket-tts serve: UP on :$PORT"
    else echo "pocket-tts serve: DOWN on :$PORT (backend uses ~7s CLI)"; fi ;;
  *) echo "Usage: pockettts-serve.sh {start|stop|status|restart}" >&2; exit 1 ;;
esac
