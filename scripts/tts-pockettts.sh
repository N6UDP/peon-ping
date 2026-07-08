#!/bin/bash
# peon-ping: pocket-tts (Kyutai) TTS backend — macOS / Linux / WSL
#
# Speaks stdin text via the `uvx pocket-tts` CLI, optionally through a shared
# `serve` daemon for warm (~3s) synthesis. Fire-and-forget: always exits 0,
# errors go to stderr gated on PEON_DEBUG=1 (matches tts-native.sh contract).
#
# Usage:
#   echo "text to speak" | tts-pockettts.sh <voice> <rate> <volume>
#
# Positional args:
#   voice   path to a pocket-tts .safetensors (or reference .wav), or "default".
#   rate    ignored — pocket-tts has no rate control (accepted for contract).
#   volume  float 0.0-1.0, applied at playback where the player supports it.
#
# Modes (config.json -> tts.pockettts):
#   daemon = false (DEFAULT): synthesize with `uvx pocket-tts generate` (~7s cold).
#   daemon = true: use a shared serve daemon (POST /tts) when healthy; if it is
#     down and daemon_auto_start is true, kick a detached multi-session-safe
#     start (pockettts-serve.sh) and speak THIS line via the CLI so nothing is
#     lost while the daemon warms up.
#
# Config keys (all optional):
#   tts.pockettts.daemon             bool  default false
#   tts.pockettts.port               int   default 8123 (env PEON_PTTS_PORT wins)
#   tts.pockettts.daemon_auto_start  bool  default true (only when daemon = true)
#
# On MSYS2/MINGW this bridges to scripts/tts-pockettts.ps1.

set -uo pipefail

PEON_DEBUG="${PEON_DEBUG:-0}"
_dbg() { [ "$PEON_DEBUG" = "1" ] && printf '[tts-pockettts] %s\n' "$*" >&2; return 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_JSON="$INSTALL_DIR/config.json"
VOICES_DIR="$INSTALL_DIR/voices"

voice="${1:-default}"
# rate ("${2:-1.0}") intentionally unused — pocket-tts has no rate control.
volume="${3:-0.5}"

# --- MSYS2/MINGW bridge to the PowerShell backend ---
case "$(uname -s)" in
  MINGW*|MSYS*)
    ps_script="$SCRIPT_DIR/tts-pockettts.ps1"
    if [ -f "$ps_script" ]; then
      IFS= read -r _t || _t=""
      printf '%s\n' "$_t" | powershell.exe -NoProfile -File "$ps_script" \
        -Voice "$voice" -Vol "$volume" 2>/dev/null || _dbg "powershell bridge failed"
    else
      _dbg "tts-pockettts.ps1 not found for MSYS bridge"
    fi
    exit 0
    ;;
esac

# --- Read one line of text from stdin ---
IFS= read -r text || text=""
if [ -z "${text//[[:space:]]/}" ]; then _dbg "empty input"; exit 0; fi

# --- Config (tts.pockettts) ---
daemon="false"
daemon_auto_start="true"
port="${PEON_PTTS_PORT:-}"
if [ -f "$CONFIG_JSON" ] && command -v python3 >/dev/null 2>&1; then
  _cfg="$(python3 -c "
import json,sys
try:
    pt=(json.load(open(sys.argv[1])).get('tts',{}) or {}).get('pockettts',{}) or {}
except Exception:
    pt={}
print(str(pt.get('daemon',False)).lower())
print(str(pt.get('daemon_auto_start',True)).lower())
print(pt.get('port',8123))
" "$CONFIG_JSON" 2>/dev/null)"
  if [ -n "$_cfg" ]; then
    daemon="$(printf '%s\n' "$_cfg" | sed -n 1p)"
    daemon_auto_start="$(printf '%s\n' "$_cfg" | sed -n 2p)"
    [ -z "$port" ] && port="$(printf '%s\n' "$_cfg" | sed -n 3p)"
  fi
fi
[ -z "$port" ] && port="8123"

# --- Voice resolution (first match wins) ---
voice_arg=""
if [ "$voice" != "default" ] && [ -f "$voice" ]; then
  voice_arg="$voice"
elif [ -f "$VOICES_DIR/peon-voice.safetensors" ]; then
  voice_arg="$VOICES_DIR/peon-voice.safetensors"
elif [ -f "$VOICES_DIR/peon-ref.wav" ]; then
  voice_arg="$VOICES_DIR/peon-ref.wav"
fi

out_wav="$(mktemp -t peon-tts-XXXXXX).wav"
produced="false"

# The serve daemon streams WAV with a placeholder data-chunk size; rewrite the
# RIFF/data sizes to the real byte counts so players read it correctly.
_repair_wav() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c "
import struct,sys
p=sys.argv[1]
b=bytearray(open(p,'rb').read())
if len(b)<44 or b[0:4]!=b'RIFF': sys.exit(0)
pos=12
while pos<len(b)-8:
    cid=bytes(b[pos:pos+4]); sz=struct.unpack('<I',b[pos+4:pos+8])[0]
    if cid==b'data':
        real=len(b)-pos-8
        if sz!=real:
            b[pos+4:pos+8]=struct.pack('<I',real)
            b[4:8]=struct.pack('<I',len(b)-8)
            open(p,'wb').write(b)
        break
    if sz==0 or sz>len(b): break
    pos+=8+sz+(sz%2)
" "$1" 2>/dev/null || true
}

# --- Playback: reuse the platform's audio player, best-effort volume ---
_play() {
  local f="$1" v="$2"
  case "$(uname -s)" in
    Darwin) afplay -v "$v" "$f" 2>/dev/null || _dbg "afplay failed" ;;
    *)
      if command -v pw-play >/dev/null 2>&1;  then pw-play --volume "$v" "$f" 2>/dev/null && return
      fi
      if command -v ffplay >/dev/null 2>&1;   then
        local pct; pct=$(awk -v x="$v" 'BEGIN{printf "%d", x*100}')
        ffplay -nodisp -autoexit -loglevel quiet -volume "$pct" "$f" 2>/dev/null && return
      fi
      if command -v paplay >/dev/null 2>&1;   then paplay "$f" 2>/dev/null && return; fi
      if command -v aplay  >/dev/null 2>&1;   then aplay -q "$f" 2>/dev/null && return; fi
      if command -v mpv    >/dev/null 2>&1;   then mpv --no-video --really-quiet "$f" 2>/dev/null && return; fi
      if command -v play   >/dev/null 2>&1;   then play -q "$f" 2>/dev/null && return; fi
      _dbg "no audio player found (tried pw-play,ffplay,paplay,aplay,mpv,play)"
      ;;
  esac
}

# --- Warm path: serve daemon (only when enabled) ---
if [ "$daemon" = "true" ] && command -v curl >/dev/null 2>&1; then
  if curl -fsS --max-time 2 "http://localhost:$port/health" >/dev/null 2>&1; then
    _dbg "serve up on :$port, POST /tts"
    if [ -n "$voice_arg" ]; then
      curl -fsS -X POST "http://localhost:$port/tts" -F "text=$text" -F "voice_wav=@$voice_arg" -o "$out_wav" 2>/dev/null
    else
      curl -fsS -X POST "http://localhost:$port/tts" -F "text=$text" -o "$out_wav" 2>/dev/null
    fi
    if [ -s "$out_wav" ]; then _repair_wav "$out_wav"; produced="true"; else _dbg "serve produced no audio"; fi
  elif [ "$daemon_auto_start" = "true" ]; then
    serve_helper="$SCRIPT_DIR/pockettts-serve.sh"
    if [ -x "$serve_helper" ] || [ -f "$serve_helper" ]; then
      _dbg "serve down on :$port; kicking detached start, using CLI for this line"
      nohup sh -c '"$0" start' "$serve_helper" >/dev/null 2>&1 &
    fi
  fi
fi

# --- Default / fallback path: uvx CLI ---
if [ "$produced" != "true" ]; then
  if command -v uvx >/dev/null 2>&1; then
    if [ -n "$voice_arg" ]; then
      uvx pocket-tts generate --text "$text" --output-path "$out_wav" -q --voice "$voice_arg" 2>/dev/null
    else
      uvx pocket-tts generate --text "$text" --output-path "$out_wav" -q 2>/dev/null
    fi
    [ -s "$out_wav" ] && produced="true"
  else
    _dbg "uvx not found; cannot synthesize"
  fi
fi

if [ "$produced" != "true" ]; then _dbg "no audio produced"; rm -f "$out_wav"; exit 0; fi

_play "$out_wav" "$volume"
rm -f "$out_wav"
exit 0
