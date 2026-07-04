# Daily Blog Engine

An unattended pipeline that researches, writes, illustrates, quality-checks, and publishes a blog post every morning using headless Claude Code, launchd, and git.

A Mac wakes itself at 5:55 AM. At 6:00 a LaunchAgent runs a thin shell wrapper that syncs your site repo and hands control to a headless Claude Code session driven by a prompt playbook. The playbook picks a topic, drafts the post, generates a featured image, runs a hard quality gate, and publishes by pushing to `main` (your host auto-deploys). At 9:00 a second LaunchAgent runs an independent copy-refinement pass with a second agent (Codex) that re-edits whatever shipped that morning.

This repo packages the scripts, the two prompt playbooks, the LaunchAgent templates, and the operations doc so you can run the same engine on your own Astro or similar git-deployed blog.

## Architecture

```
05:55 daily  pmset wakes the Mac
06:00 daily  launchd (LaunchAgent) --> scripts/daily-blog.sh
                                          |- git checkout main && git pull
                                          |- source .env.local (GOOGLE_API_KEY...)
                                          |- claude -p scripts/daily-blog-prompt.md   [headless]
                                          |     topic pick -> draft -> image -> QUALITY GATE
                                          |       pass -> draft:false + push main -> host deploys
                                          |       fail -> draft:true + push auto/blog-<date> branch
                                          |- row appended to tasks/daily-blog-log.md

09:00 daily  launchd (LaunchAgent) --> scripts/daily-blog-copy-pass.sh
                                          |- git checkout main && git pull
                                          |- codex exec < scripts/daily-blog-copy-pass-prompt.md
                                          |- check today's post published
                                          |- simplify and de-AI the copy if needed
                                          |- npm run build + generated route check
                                          |- commit/push the copy pass or no-change log
                                          |- row appended to tasks/daily-copy-pass-log.md
```

## How it works

**The 6AM publish pass.** `scripts/daily-blog.sh` is deliberately thin: it takes a lock, checks preflight (Claude CLI present, `.env.local` present), syncs `main`, loads env, and runs `claude -p` with the contents of `scripts/daily-blog-prompt.md`. All content logic lives in that playbook, not in shell. The playbook loads your repo's rule files, optionally drains a queue of pre-written drafts, otherwise researches a topic with live web searches, writes the post to `src/content/blog/`, writes an image prompt and calls `scripts/gen-blog-image.mjs`, runs two anti-AI-tell edit passes, then runs the quality gate.

**The quality gate.** Four hard checks, all must pass to publish: every cited external URL must return 2xx/3xx via curl, the post must contain no em dashes, the frontmatter must match the content schema (real author, valid category enums, 2 to 3 FAQs), and `npm run build` must exit 0.

**Publish or hold.** If the gate passes, the post ships with `draft: false`, a commit, and a push to `main`, which triggers the host's auto-deploy. If any check fails and cannot be fixed, the post is held: `draft: true`, committed to a branch named `auto/blog-<date>`, pushed there, and never touches `main`. Every run, publish or hold, appends a row to `tasks/daily-blog-log.md` so you can audit the engine from one file.

**Deterministic fallback.** If the headless Claude run itself fails, the wrapper can still ship the day: it reads `scripts/publish-queue.txt` (optional, one slug per line of pre-written drafts), flips the next held draft to `draft: false`, generates its image if missing, gates on a clean build, and pushes. It generates no content of its own. No queue file means no fallback, and the day is simply skipped.

**The 9AM copy pass.** A separate wrapper hands `scripts/daily-blog-copy-pass-prompt.md` to the Codex CLI. It finds the post published today, applies conservative de-AI and readability edits, protects the SEO structure (never removes keywords, citations, tables, FAQs, or links), re-runs the full quality gate including a check of the built HTML, and logs `UPDATED`, `NO_CHANGE`, `NO_POST`, or `HELD` to `tasks/daily-copy-pass-log.md`. It can optionally email you the result via Resend (`scripts/send-copy-pass-report.mjs`).

**Dry runs.** Both wrappers accept `DRY_RUN=1`, which forces the branch-only hold path and never touches `main`. Always smoke test with a dry run before installing the schedule.

## Requirements

- A Mac that can stay plugged in and wake on schedule (any Apple Silicon laptop or mini; a dedicated machine is ideal). launchd and pmset are macOS-only.
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated. The 6AM publisher runs it headless with `-p`.
- Optionally the Codex CLI, authenticated, for the 9AM copy pass. Skip installing the second LaunchAgent if you do not want it. You can also point the wrapper at any other headless coding agent.
- An Astro or similar static blog in a git repo where pushing `main` deploys (Vercel, Netlify, Cloudflare Pages). The playbooks assume markdown posts in `src/content/blog/` with frontmatter and `npm run build` as the gate command: adjust paths in the playbooks if yours differ.
- `.env.local` in the site repo with `GOOGLE_API_KEY` (Gemini, primary image model) and optionally `OPENAI_API_KEY` (gpt-image-1 fallback). The generator falls back to a committed placeholder image if both fail, so image outages never block publishing.

## Setup

These scripts live inside your site repo, not beside it. Copy `scripts/` into your site repo and commit it, then on the Mac that will run the engine:

1. Clone and install:
   ```sh
   git clone <your-site-repo-url> ~/path/to/your-site
   cd ~/path/to/your-site
   npm install
   ```
2. Create `.env.local` with `GOOGLE_API_KEY` (and optionally `OPENAI_API_KEY`, plus the Resend variables if you want the 9AM email report). This file is gitignored.
3. Authenticate Claude Code once, interactively, inside the repo:
   ```sh
   claude
   ```
   This confirms login and accepts the project trust prompt. Headless runs cannot answer either prompt, so do this by hand once. If you use the copy pass, also run `codex login`.
4. Customize the playbooks. See "Adapting the playbook" below. Do not skip this: the shipped playbooks are a working example for a hypothetical site, not yours.
5. Smoke test with dry runs (branch only, never touches `main`):
   ```sh
   chmod +x scripts/daily-blog.sh scripts/daily-blog-copy-pass.sh
   DRY_RUN=1 bash scripts/daily-blog.sh
   tail -n 40 ~/Library/Logs/daily-blog.out
   ```
6. Install the LaunchAgents from the samples:
   ```sh
   sed -e "s#__REPO_DIR__#$PWD#g" -e "s#__HOME__#$HOME#g" \
     scripts/com.example.dailyblog.plist.sample \
     > ~/Library/LaunchAgents/com.example.dailyblog.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.dailyblog.plist

   sed -e "s#__REPO_DIR__#$PWD#g" -e "s#__HOME__#$HOME#g" \
     scripts/com.example.dailyblogcopypass.plist.sample \
     > ~/Library/LaunchAgents/com.example.dailyblogcopypass.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.dailyblogcopypass.plist
   ```
7. Schedule the wake. launchd will not wake a sleeping Mac, so this step is required:
   ```sh
   sudo pmset repeat wake MTWRFSU 05:55:00
   pmset -g sched
   ```
8. Watch the logs for the first weeks:
   - `~/Library/Logs/daily-blog.out` and `daily-blog.err`
   - `~/Library/Logs/daily-blog-copy-pass.out` and `.err`
   - `tasks/daily-blog-log.md` and `tasks/daily-copy-pass-log.md` in the repo
   - `git branch -r | grep auto/blog` for held drafts awaiting review

Operating constraints: keep the Mac on AC power, enable auto-login, and keep the lid open (clamshell wake is unreliable). Full setup detail, verification routine, troubleshooting, and teardown are in [docs/architecture.md](docs/architecture.md).

## Adapting the playbook

`scripts/daily-blog-prompt.md` is the brain. The shell wrappers are deterministic plumbing you should rarely touch; the playbook is where the engine's judgment lives, and it ships as a complete working example you edit rather than a fill-in-the-blank template. Every place that needs your site's specifics is marked with a `<!-- CUSTOMIZE: ... -->` comment:

- **Header:** your site name and one line on what the site is.
- **STEP 0:** which rule/context files in your repo the engine reads first (style rules, strategy, accumulated lessons, post history).
- **Style rules:** the example house rules (no em dashes, conservative numbers, no invented authors, verified URLs only). Keep the last two in some form.
- **STEP 0.5:** the optional pre-written publish queue. Delete the whole step if you never batch-draft ahead.
- **STEP 1:** the topic strategy. The example is a two-bucket commercial/authority split with a target ratio and an anti-drift rule. Replace with yours.
- **STEP 2:** money pages for in-body conversion links.
- **STEP 3:** the frontmatter shape, author names, and category enums, which must match your content schema.
- **STEP 4:** your brand image style (colors, composition).
- **STEP 5:** where your author map lives.
- **STEP 6:** your domain and IndexNow key, or delete the IndexNow block.
- **STEP 7:** whether to update an llms.txt style index.

`scripts/daily-blog-copy-pass-prompt.md` has the same markers for the 9AM pass: site name, rule files, primary CTA string, schema locations, and build output paths.

## Safety and cost

Be clear-eyed about what this is: a headless LLM with git push rights to your production site, running on a schedule with no human review. The design contains that risk in layers rather than pretending it away:

- **The quality gate is a floor, not an editor.** It catches dead links, schema breakage, banned punctuation, and build failures. It does not catch a mediocre take. Audit the output regularly and drop days if quality slips.
- **Fail toward drafts.** Any unfixable gate failure lands on an `auto/blog-<date>` branch, never `main`. `DRY_RUN=1` forces that path for testing.
- **Scoped tools.** The Claude run uses `--permission-mode acceptEdits` with an explicit `--allowedTools` list, not blanket permission bypass. The Codex wrapper does use its bypass flag, so treat the copy-pass playbook's constraints as the control there.
- **Bounded fallback.** The deterministic fallback only flips pre-written, pre-verified drafts and is gated on a clean build. It never generates content.
- **Deterministic wrappers.** Locking, syncing, env, and scheduling are plain shell, so the only nondeterministic component is the model run itself, and everything it does is logged to one append-only file per job.
- **Scaled-content risk.** Daily unreviewed AI posts can trip search engines' scaled content abuse policies. This is a publishing tool, not a content farm kit: keep the playbook opinionated, keep citations real, and review monthly.

Approximate cost per day: if Claude Code runs on a Claude subscription (Pro/Max), the 6AM run is included. On API billing, expect roughly $1 to $3 per run depending on model and how much web research the topic takes. Image generation adds a few cents (Gemini) up to about $0.25 (gpt-image-1 fallback). The Codex pass is likewise included in a ChatGPT subscription or a comparable small API cost. Order of magnitude: a dollar or three a day, or near zero on flat-rate subscriptions.

## Files

```
README.md
LICENSE
docs/architecture.md                            setup, operations, troubleshooting, teardown
scripts/daily-blog.sh                           6AM wrapper + deterministic fallback
scripts/daily-blog-prompt.md                    the publish playbook (the brain)
scripts/daily-blog-copy-pass.sh                 9AM wrapper
scripts/daily-blog-copy-pass-prompt.md          the copy-refinement playbook
scripts/gen-blog-image.mjs                      image generator: Gemini -> OpenAI -> placeholder
scripts/send-copy-pass-report.mjs               optional Resend email report
scripts/com.example.dailyblog.plist.sample      6AM LaunchAgent template
scripts/com.example.dailyblogcopypass.plist.sample  9AM LaunchAgent template
```

## License

MIT. See [LICENSE](LICENSE).
