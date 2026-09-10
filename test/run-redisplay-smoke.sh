#!/usr/bin/env sh
# Exercise the real Emacs command loop inside a disposable pseudo-terminal.
set -eu

dwindle_smoke_dir=$(mktemp -d "${TMPDIR:-/tmp}/dwindle-smoke.XXXXXX")
trap 'rm -rf "$dwindle_smoke_dir"' 0
trap 'exit 1' HUP INT TERM

DWINDLE_SMOKE_PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DWINDLE_SMOKE_RESULT="$dwindle_smoke_dir/result"
DWINDLE_SMOKE_EMACS=${EMACS:-emacs}
export DWINDLE_SMOKE_PROJECT DWINDLE_SMOKE_RESULT DWINDLE_SMOKE_EMACS
export TERM=xterm

dwindle_smoke_status=0
"${TIMEOUT:-timeout}" -k 2s "${SMOKE_TIMEOUT:-15}s" \
  script -q -e -c \
  '"$DWINDLE_SMOKE_EMACS" -Q -nw -L "$DWINDLE_SMOKE_PROJECT" -l "$DWINDLE_SMOKE_PROJECT/test/dwindle-redisplay-smoke.el"' \
  "$dwindle_smoke_dir/terminal.log" \
  </dev/null >"$dwindle_smoke_dir/driver.log" 2>&1 \
  || dwindle_smoke_status=$?

if [ -s "$DWINDLE_SMOKE_RESULT" ]; then
  cat "$DWINDLE_SMOKE_RESULT"
else
  printf '%s\n' 'FAIL: Emacs did not produce a smoke-test result.' >&2
  if [ "$dwindle_smoke_status" -eq 0 ]; then
    dwindle_smoke_status=1
  fi
fi

if [ "$dwindle_smoke_status" -ne 0 ]; then
  tail -n 15 "$dwindle_smoke_dir/driver.log" >&2
  if [ -f "$dwindle_smoke_dir/terminal.log" ]; then
    tail -n 15 "$dwindle_smoke_dir/terminal.log" >&2
  fi
fi
exit "$dwindle_smoke_status"
