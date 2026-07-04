# Daily Blog Engine — Setup & Operations

A dedicated Mac (any Apple Silicon laptop or mini works) wakes every morning, runs
the publishing engine at 6:00 AM, then runs a separate copy-refinement pass at 9:00
AM. The 9AM pass checks that today's post published, applies conservative
simplification edits, verifies the post, and logs what changed.

These scripts are designed to live inside YOUR site repo (an Astro or similar
git-deployed static blog). Copy the `scripts/` directory into your site repo,
customize the two prompt playbooks, and follow the setup below.

## How it works

```
05:55 daily  pmset wakes the Mac
06:00 daily  launchd (LaunchAgent) ──► scripts/daily-blog.sh
                                            ├─ git checkout main && git pull
                                            ├─ source .env.local (GOOGLE_API_KEY…)
                                            └─ claude -p scripts/daily-blog-prompt.md   [headless]
                                                  topic pick → draft → image → QUALITY GATE
                                                    pass → draft:false + push main → host auto-deploys
                                                    fail → draft:true + push auto/blog-<date> branch
                                            └─ row appended to tasks/daily-blog-log.md

09:00 daily  launchd (LaunchAgent) ──► scripts/daily-blog-copy-pass.sh
                                            ├─ git checkout main && git pull
                                            ├─ codex exec < scripts/daily-blog-copy-pass-prompt.md
                                            ├─ check today's post published
                                            ├─ simplify/de-AI the copy if needed
                                            ├─ npm run build + generated route check
                                            ├─ commit/push the copy pass or no-change log
                                            └─ row appended to tasks/daily-copy-pass-log.md
```

Pieces (all committed except the live plist):
- `scripts/daily-blog.sh` — thin wrapper: sync, env, hand off to Claude. No content logic.
- `scripts/daily-blog-prompt.md` — the playbook (the brain). Edit this to change behavior.
- `scripts/com.example.dailyblog.plist.sample` — LaunchAgent template.
- `tasks/daily-blog-log.md` — append-only run log (created in your site repo).
- `scripts/daily-blog-copy-pass.sh` — thin wrapper for the 9AM Codex copy pass.
- `scripts/daily-blog-copy-pass-prompt.md` — the copy-refinement playbook.
- `scripts/com.example.dailyblogcopypass.plist.sample` — 9AM LaunchAgent template.
- `tasks/daily-copy-pass-log.md` — append-only copy-pass report log.
- `scripts/send-copy-pass-report.mjs` — optional email reporter for the latest copy-pass row.
- `scripts/gen-blog-image.mjs` — featured-image generator (Gemini → OpenAI → placeholder).
- `scripts/publish-queue.txt` — optional: one slug per line for the deterministic
  on-failure fallback in `daily-blog.sh` (see that script's comments).

## One-time setup on the Mac

1. **Clone + install** (your site repo, with these scripts copied in)
   ```sh
   git clone <your-site-repo-url> ~/path/to/your-site
   cd ~/path/to/your-site
   npm install
   ```
2. **Add secrets:** create `.env.local` (must contain `GOOGLE_API_KEY`; `OPENAI_API_KEY`
   optional fallback). This file is gitignored and will NOT come from the clone.
   Optional copy-pass email reporting uses:
   ```sh
   COPY_PASS_REPORT_EMAIL=you@example.com
   COPY_PASS_REPORT_FROM="My Site <approved-sender@yourdomain.com>"
   RESEND_API_KEY=<your Resend key>
   ```
3. **Install + authenticate Claude Code** on this Mac, then run `claude` once
   interactively inside the repo to (a) confirm login and (b) accept the project trust
   prompt. Headless runs cannot answer either prompt, so this must be done by hand once.
   The 6AM publisher uses Claude.
4. **Install + authenticate Codex** on this Mac (optional; only needed for the 9AM
   copy pass). Confirm `codex --version` works and run `codex login` if needed.
5. **Make the wrappers executable:**
   ```sh
   chmod +x scripts/daily-blog.sh scripts/daily-blog-copy-pass.sh
   ```
6. **Smoke test the publisher wrapper manually** (holds as a draft branch, never touches main):
   ```sh
   DRY_RUN=1 bash scripts/daily-blog.sh
   tail -n 40 ~/Library/Logs/daily-blog.out
   ```
   Confirm a post + image landed on an `auto/blog-dryrun-*` branch and `npm run build` passed.
7. **Smoke test the 9AM copy pass** (branch only, never touches main):
   ```sh
   DRY_RUN=1 bash scripts/daily-blog-copy-pass.sh
   tail -n 60 ~/Library/Logs/daily-blog-copy-pass.out
   ```
   Confirm `tasks/daily-copy-pass-log.md` records `UPDATED`, `NO_CHANGE`, `NO_POST`, or `HELD`.

## Install the schedule

1. **6AM LaunchAgent:** copy the sample, fill the two placeholders, install, load.
   ```sh
   sed -e "s#__REPO_DIR__#$PWD#g" -e "s#__HOME__#$HOME#g" \
     scripts/com.example.dailyblog.plist.sample \
     > ~/Library/LaunchAgents/com.example.dailyblog.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.dailyblog.plist
   launchctl print gui/$(id -u)/com.example.dailyblog   # verify it's loaded
   ```
2. **9AM copy-pass LaunchAgent:** install the second sample.
   ```sh
   sed -e "s#__REPO_DIR__#$PWD#g" -e "s#__HOME__#$HOME#g" \
     scripts/com.example.dailyblogcopypass.plist.sample \
     > ~/Library/LaunchAgents/com.example.dailyblogcopypass.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.dailyblogcopypass.plist
   launchctl print gui/$(id -u)/com.example.dailyblogcopypass
   ```
3. **Scheduled wake (required — launchd will NOT wake a sleeping Mac):**
   ```sh
   sudo pmset repeat wake MTWRFSU 05:55:00
   pmset -g sched     # verify the repeating wake is registered
   ```

## Operating constraints (must all hold for a run to fire)

- **Plugged into AC power.** Battery sleep can block scheduled wake.
- **Auto-login enabled** (System Settings → Users & Groups). A LaunchAgent needs an
  active GUI user session; without auto-login after a reboot, nothing runs.
- **Lid open is safest.** Clamshell (closed-lid) wake is unreliable without external
  power + display. If you must close the lid, test the wake path first.
- **Claude Code stays logged in for the 6AM publisher.** Tokens refresh automatically,
  but if login lapses, runs fail into the log until you re-auth (see Troubleshooting).
- **Codex stays logged in for the 9AM reviewer.** If Codex auth expires, the copy pass
  fails into `~/Library/Logs/daily-blog-copy-pass.out` until you run `codex login`.

## Daily verification (first weeks)

- `tail -n 60 ~/Library/Logs/daily-blog.out` — publisher wrapper-level log.
- `tail -n 60 ~/Library/Logs/daily-blog-copy-pass.out` — 9AM copy-pass wrapper log.
- `git -C <repo> log --oneline -5` — confirm today's publish commit on `main`.
- Bottom of `tasks/daily-blog-log.md` — one row per run (PUBLISHED vs HELD + reason).
- Bottom of `tasks/daily-copy-pass-log.md` — one row per copy pass with the daily change summary.
- `git branch -r | grep auto/blog` — any HELD drafts waiting for your review.
- If `COPY_PASS_REPORT_EMAIL` is configured, check email for the latest 9AM row.

## Changing behavior

- **Topic strategy, content rules, gate:** edit `scripts/daily-blog-prompt.md`.
- **9AM copy-pass rules:** edit `scripts/daily-blog-copy-pass-prompt.md`.
- **Cadence (drop/add days):** edit the `StartCalendarInterval` array in the live plist
  and the `pmset repeat wake` day string, then re-`bootstrap`.
- **Time of day:** change `Hour`/`Minute` in the plist and the `pmset` time.

## Troubleshooting

- **Nothing ran:** Mac asleep/off/unplugged, or not logged in. Check `pmset -g log | grep -i wake`.
- **6AM `claude` not found / hung:** ensure `PATH` in the plist `EnvironmentVariables`
  covers `~/.local/bin` and homebrew. If runs deny tool calls, the playbook may have
  tried a tool outside the allowlist — widen `--allowedTools` in `scripts/daily-blog.sh`,
  or as a last resort switch to `--dangerously-skip-permissions` (less safe).
- **9AM `codex` not found:** ensure `PATH` covers the Codex CLI or set `CODEX_BIN` in
  the LaunchAgent environment. The wrapper also checks `/Applications/Codex.app/Contents/Resources/codex`.
- **Auth expired:** run `claude` interactively for the 6AM publisher, or `codex login`
  for the 9AM reviewer.
- **Published something bad:** the gate only checks build/links/schema/em-dashes, not
  editorial quality. Do a periodic manual audit; revert with a normal git commit.
- **No copy-pass email:** confirm `COPY_PASS_REPORT_EMAIL`, `COPY_PASS_REPORT_FROM`,
  and `RESEND_API_KEY` are set in `.env.local`. Email failure is non-fatal; the report
  still lands in `tasks/daily-copy-pass-log.md`.

## Teardown

```sh
launchctl bootout gui/$(id -u)/com.example.dailyblog
launchctl bootout gui/$(id -u)/com.example.dailyblogcopypass
rm ~/Library/LaunchAgents/com.example.dailyblog.plist
rm ~/Library/LaunchAgents/com.example.dailyblogcopypass.plist
sudo pmset repeat cancel
```

## Risks (acknowledged)

- **Scaled-content risk:** daily unreviewed AI posts can trip Google's "scaled
  content abuse" policy. The gate enforces a floor, not editorial quality. Audit monthly;
  drop days if quality slips.
- **No retry:** a missed morning (asleep/offline) is simply skipped. Harmless.
- **Copy pass is bounded:** it tightens the post that already published. It does not
  pick topics, generate images, or publish held drafts.
