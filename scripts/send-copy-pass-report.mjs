// Optional email report for the 9AM copy pass, sent via Resend.
// Skips silently when COPY_PASS_REPORT_EMAIL or RESEND_API_KEY is not set.
import fs from 'node:fs';
import path from 'node:path';

const repoDir = process.cwd();
const reportEmail = process.env.COPY_PASS_REPORT_EMAIL;
const resendKey = process.env.RESEND_API_KEY;
const fromEmail = process.env.COPY_PASS_REPORT_FROM || 'My Site <hello@example.com>';
const status = process.argv[2] || 'ok';
const logPath = path.join(repoDir, 'tasks', 'daily-copy-pass-log.md');

function latestLogRow() {
  if (!fs.existsSync(logPath)) return null;
  const rows = fs.readFileSync(logPath, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('| ') && !line.includes('---') && !line.includes('Date | Slug'));
  return rows.at(-1) || null;
}

if (!reportEmail || !resendKey) {
  console.log('COPY_PASS_REPORT_EMAIL or RESEND_API_KEY missing; email report skipped.');
  process.exit(0);
}

const row = latestLogRow();
const subject = status === 'ok'
  ? 'Daily blog copy pass complete'
  : 'Daily blog copy pass failed';
const text = status === 'ok'
  ? `The 9AM blog copy pass finished.\n\nLatest log row:\n${row || 'No log row found.'}\n\nRepo log: tasks/daily-copy-pass-log.md`
  : `The 9AM blog copy pass failed. Check ~/Library/Logs/daily-blog-copy-pass.out and ~/Library/Logs/daily-blog-copy-pass.err.\n\nLatest log row:\n${row || 'No log row found.'}`;

const response = await fetch('https://api.resend.com/emails', {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${resendKey}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    from: fromEmail,
    to: [reportEmail],
    subject,
    text,
  }),
});

if (!response.ok) {
  const body = await response.text();
  console.error(`Resend report failed (${response.status}): ${body}`);
  process.exit(1);
}

console.log(`Copy pass report emailed to ${reportEmail}.`);
