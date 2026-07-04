#!/usr/bin/env bash
#
# daily-blog-copy-pass.sh — 9AM blog QA/copy refinement wrapper.
#
# Triggered by a macOS LaunchAgent after the daily publisher has had time to run.
# It syncs the repo, loads local env, and hands control to a headless Codex
# run driven by scripts/daily-blog-copy-pass-prompt.md.
#
# Manual run:   bash scripts/daily-blog-copy-pass.sh
# Dry run:      DRY_RUN=1 bash scripts/daily-blog-copy-pass.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

CODEX_BIN="${CODEX_BIN:-}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs}"
RUN_LOG="$LOG_DIR/daily-blog-copy-pass.out"
CODEX_SUMMARY="$LOG_DIR/daily-blog-copy-pass.codex-summary.txt"
LOCK="$REPO_DIR/.daily-blog-copy-pass.lock"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$RUN_LOG"; }

if [ -e "$LOCK" ]; then
  log "SKIP: lock file $LOCK exists; a prior copy pass may still be active."
  exit 0
fi
trap 'rm -f "$LOCK"' EXIT
echo "$$" > "$LOCK"

log "=== daily blog copy pass start (repo: $REPO_DIR, dry_run: ${DRY_RUN:-0}) ==="

if [ -z "$CODEX_BIN" ]; then
  if command -v codex >/dev/null 2>&1; then
    CODEX_BIN="$(command -v codex)"
  elif [ -x "/Applications/Codex.app/Contents/Resources/codex" ]; then
    CODEX_BIN="/Applications/Codex.app/Contents/Resources/codex"
  else
    log "FATAL: Codex CLI not found on PATH or at /Applications/Codex.app/Contents/Resources/codex."
    exit 1
  fi
elif [ ! -x "$CODEX_BIN" ]; then
  log "FATAL: CODEX_BIN is set but not executable: $CODEX_BIN"
  exit 1
fi

log "Using Codex CLI: $CODEX_BIN"

if [ -f "$REPO_DIR/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env.local"
  set +a
else
  log "WARN: .env.local missing; continuing without optional notification env."
fi

git checkout main >>"$RUN_LOG" 2>&1 || { log "FATAL: git checkout main failed."; exit 1; }
if ! git pull --ff-only >>"$RUN_LOG" 2>&1; then
  log "FATAL: git pull --ff-only failed; refusing to edit on a stale or divergent main."
  exit 1
fi

PROMPT_FILE="$SCRIPT_DIR/daily-blog-copy-pass-prompt.md"
[ -f "$PROMPT_FILE" ] || { log "FATAL: prompt file $PROMPT_FILE missing."; exit 1; }

PROMPT="$(cat "$PROMPT_FILE")"
if [ "${DRY_RUN:-0}" = "1" ]; then
  PROMPT="DRY RUN MODE: do not push to main. You may edit files and run checks, but commit only to a branch named auto/copy-pass-dryrun-\$(date +%Y%m%d) and push that branch if changes were made. Otherwise follow every instruction below.

$PROMPT"
fi

set +e
printf '%s\n' "$PROMPT" | "$CODEX_BIN" exec \
  --cd "$REPO_DIR" \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message "$CODEX_SUMMARY" \
  - \
  >>"$RUN_LOG" 2>&1
STATUS=$?
set -e

if [ $STATUS -eq 0 ]; then
  log "=== daily blog copy pass finished OK (see tasks/daily-copy-pass-log.md) ==="
  if command -v node >/dev/null 2>&1; then
    node scripts/send-copy-pass-report.mjs ok >>"$RUN_LOG" 2>&1 || log "WARN: email report failed; copy pass already completed."
  fi
  exit 0
fi

log "=== daily blog copy pass FAILED (codex exit $STATUS); see $RUN_LOG ==="
if command -v node >/dev/null 2>&1; then
  node scripts/send-copy-pass-report.mjs failed >>"$RUN_LOG" 2>&1 || true
fi
exit $STATUS
