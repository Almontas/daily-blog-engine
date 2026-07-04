#!/usr/bin/env bash
#
# daily-blog.sh — daily 6AM auto-blog engine wrapper (runs 7 days/week).
#
# Triggered by a macOS LaunchAgent (see docs/architecture.md). Thin and
# deterministic: it syncs the repo, loads env, and hands control to a headless
# Claude Code run driven by scripts/daily-blog-prompt.md. ALL content logic
# (topic pick, draft, image, quality gate, publish) lives in that prompt, not here.
#
# Manual run:   bash scripts/daily-blog.sh
# Dry run:      DRY_RUN=1 bash scripts/daily-blog.sh   # prompt holds as draft, never pushes main
#
set -euo pipefail

# --- Resolve repo root from this script's location (portable across machines) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs}"
RUN_LOG="$LOG_DIR/daily-blog.out"
LOCK="$REPO_DIR/.daily-blog.lock"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$RUN_LOG"; }

# --- Single-run lock (skip if a previous run is still going) ---
if [ -e "$LOCK" ]; then
  log "SKIP: lock file $LOCK exists; a prior run may still be active."
  exit 0
fi
trap 'rm -f "$LOCK"' EXIT
echo "$$" > "$LOCK"

log "=== daily-blog run start (repo: $REPO_DIR, dry_run: ${DRY_RUN:-0}) ==="

# --- Preflight ---
if [ ! -x "$CLAUDE_BIN" ] && ! command -v claude >/dev/null 2>&1; then
  log "FATAL: claude CLI not found at $CLAUDE_BIN and not on PATH."
  exit 1
fi
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude)"

if [ ! -f "$REPO_DIR/.env.local" ]; then
  log "FATAL: .env.local missing (needs GOOGLE_API_KEY for image generation)."
  exit 1
fi

# --- Sync repo to latest main ---
git checkout main >>"$RUN_LOG" 2>&1 || { log "FATAL: git checkout main failed."; exit 1; }
if ! git pull --ff-only >>"$RUN_LOG" 2>&1; then
  log "WARN: git pull --ff-only failed (local divergence?); continuing on current main."
fi

# --- Load API keys (GOOGLE_API_KEY, OPENAI_API_KEY, etc.) ---
set -a
# shellcheck disable=SC1091
source "$REPO_DIR/.env.local"
set +a

# --- Hand off to the headless Claude run ---
PROMPT_FILE="$SCRIPT_DIR/daily-blog-prompt.md"
[ -f "$PROMPT_FILE" ] || { log "FATAL: prompt file $PROMPT_FILE missing."; exit 1; }

# DRY_RUN=1 instructs the prompt to hold output as a draft branch and never push main.
PROMPT="$(cat "$PROMPT_FILE")"
if [ "${DRY_RUN:-0}" = "1" ]; then
  PROMPT="DRY RUN MODE: do not push to main and do not set draft:false. Force draft:true, commit to a branch named auto/blog-dryrun-\$(date +%Y%m%d) and push that branch only. Otherwise follow every instruction below.

$PROMPT"
fi

set +e
"$CLAUDE_BIN" -p "$PROMPT" \
  --permission-mode acceptEdits \
  --allowedTools "Bash Edit Write Read WebSearch WebFetch Glob Grep" \
  >>"$RUN_LOG" 2>&1
STATUS=$?
set -e

if [ $STATUS -eq 0 ]; then
  log "=== daily-blog run finished OK (see tasks/daily-blog-log.md for what shipped) ==="
  exit 0
fi

log "=== daily-blog run FAILED (claude exit $STATUS) — attempting deterministic on-failure fallback ==="

# ---------------------------------------------------------------------------
# ON-FAILURE FALLBACK (integrated here — NOT a separate scheduler).
# If the headless Claude run fails, still ship the day's post deterministically:
# publish the NEXT held pre-written queue draft by flipping its draft flag and
# pushing via git (the same toolchain this wrapper already uses). Bounded by:
#   * never runs in DRY_RUN,
#   * idempotent — no-op if any post already published today,
#   * only publishes a pre-built queue draft (generates no content),
#   * gated on a clean `npm run build` so a broken post never reaches main.
# SCOPE: runs only when THIS wrapper runs. It cannot cover the LaunchAgent failing
# to launch at all (e.g. macOS Full Disk Access revoked -> exit 126) — nothing on
# the Mac can self-heal "the Mac can't run the job." That stays a manual fix.
#
# CUSTOMIZE: the queue lives in scripts/publish-queue.txt, one slug per line, in
# publish order. Each slug must correspond to a pre-written, pre-verified draft
# at src/content/blog/<slug>.md committed with `draft: true`. If you do not keep
# a queue of pre-written drafts, leave publish-queue.txt absent: the fallback
# then simply reports "no queue" and the original failure stands (a missed day,
# which is harmless).
# ---------------------------------------------------------------------------
if [ "${DRY_RUN:-0}" = "1" ]; then
  log "FALLBACK: skipped (DRY_RUN=1 trial mode)."
  exit $STATUS
fi

QUEUE_FILE="$SCRIPT_DIR/publish-queue.txt"

set +e
fallback_publish() {
  local today next slug f img cand title img_slug now
  today="$(date +%Y-%m-%d)"

  # Idempotency: if any post already carries today's date AND is live, do nothing.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if grep -q "^draft: false" "$cand"; then
      log "FALLBACK: a post already published today ($cand) — nothing to do."
      return 0
    fi
  done < <(grep -rl "publishDate: ${today}T" "$REPO_DIR/src/content/blog/" 2>/dev/null)

  if [ ! -f "$QUEUE_FILE" ]; then
    log "FALLBACK: no publish queue ($QUEUE_FILE missing) — nothing to publish."
    return 1
  fi

  # Take the first queue slug that is still draft: true. Already-published slugs
  # are draft:false and skipped automatically.
  next=""
  while IFS= read -r slug; do
    slug="${slug%%#*}"; slug="$(echo "$slug" | tr -d '[:space:]')"
    [ -n "$slug" ] || continue
    f="$REPO_DIR/src/content/blog/${slug}.md"
    [ -f "$f" ] || continue
    grep -q "^draft: true" "$f" && { next="$slug"; break; }
  done < "$QUEUE_FILE"

  if [ -z "${next:-}" ]; then
    log "FALLBACK: no held queue draft left (queue drained) — nothing to publish."
    return 1
  fi
  f="$REPO_DIR/src/content/blog/${next}.md"

  # Featured image: generate at publish time if missing. gen-blog-image.mjs runs
  # Gemini -> OpenAI -> placeholder and exits 0 on any success, so a missing
  # image never holds a queue post. Prompt is built from the post title.
  # CUSTOMIZE: the prompt below encodes an example brand image style (dark
  # background, gold accents). Replace it with your own brand image rules.
  img="$(grep -m1 '^featuredImage:' "$f" | sed -E 's/.*"([^"]+)".*/\1/')"
  if [ -n "$img" ] && [ ! -f "$REPO_DIR/public${img}" ]; then
    log "FALLBACK: image missing for '$next' (public${img}) — generating at publish time."
    title="$(grep -m1 '^title:' "$f" | sed -E 's/^title: *"?([^"]*)"?$/\1/')"
    img_slug="$(basename "$img" .png)"; img_slug="${img_slug#blog-}"
    node "$REPO_DIR/scripts/gen-blog-image.mjs" --slug "$img_slug" --prompt \
      "Iconographic wireframe illustration with ONE clearly identifiable literal subject representing this article topic: ${title}. Dark background (#0a0a0a), warm gold (#8B6914) accents, white elements, generous dark negative space, no text, words, or labels, landscape format, professional, clean, not cluttered." \
      >>"$RUN_LOG" 2>&1
    if [ ! -f "$REPO_DIR/public${img}" ]; then
      log "FALLBACK: image generation failed for '$next' — holding, not publishing."
      return 1
    fi
  fi

  log "FALLBACK: publishing next held draft '$next'."
  # Real publish time in UTC. The site build serializes a naive publishDate as-is
  # with a Z suffix (treats it as UTC), so stamp UTC to keep the rendered instant
  # truthful. Keep the time-of-day component (never bare date / midnight) so a TZ
  # display conversion can't roll the byline back a day.
  now="$(date -u '+%Y-%m-%dT%H:%M:%S')"
  perl -0pi -e 's/^draft: true$/draft: false/m'                "$f"
  perl -0pi -e "s/^publishDate: .*\$/publishDate: ${now}/m"    "$f"
  # CUSTOMIZE (optional): mechanical CTA normalize. This fallback path can't run
  # the Claude edit passes, so if your queue drafts ship with an outdated CTA
  # label, fix it mechanically here. Example (adjust to your own CTA strings):
  # perl -0pi -e 's/>Old CTA Label<\/a>/>New CTA Label<\/a>/g' "$f"

  # Build gate — never push a broken main.
  if ! npm run build >>"$RUN_LOG" 2>&1; then
    log "FALLBACK: build failed after flipping '$next' — reverting, not pushing."
    git checkout -- "$f" >>"$RUN_LOG" 2>&1
    return 1
  fi

  printf '| %s | %s | %s | %s | %s | %s |\n' \
    "$today" "$next" "Queue publish (engine on-failure fallback)" "PUBLISHED" \
    "/blog/${next}" "Primary Claude run failed (exit ${STATUS}); fallback flipped the next held draft and pushed." \
    >> "$REPO_DIR/tasks/daily-blog-log.md"

  git add "$f" "$REPO_DIR/tasks/daily-blog-log.md" >>"$RUN_LOG" 2>&1
  [ -n "$img" ] && [ -f "$REPO_DIR/public${img}" ] && git add "$REPO_DIR/public${img}" >>"$RUN_LOG" 2>&1
  git commit -m "Publish queue post (engine fallback): ${next}" >>"$RUN_LOG" 2>&1
  if git push origin main >>"$RUN_LOG" 2>&1; then
    log "FALLBACK: published and pushed '$next'."
    return 0
  fi
  log "FALLBACK: git push failed for '$next'."
  return 1
}

if fallback_publish; then
  log "=== daily-blog on-failure fallback completed ==="
  exit 0
fi
log "=== daily-blog fallback did not publish — original failure (exit $STATUS) stands ==="
exit $STATUS
