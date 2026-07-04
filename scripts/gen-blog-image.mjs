// Shared blog featured-image generator with retry + fallback chain:
//   1. Gemini (gemini-3-pro-image-preview), 2 attempts with backoff
//   2. OpenAI gpt-image-1, 1 attempt (if OPENAI_API_KEY present)
//   3. Copy public/images/blog-placeholder.png (post still ships; regenerate later)
//
// Usage:
//   node scripts/gen-blog-image.mjs --slug <slug> --prompt-file <path>
//   node scripts/gen-blog-image.mjs --slug <slug> --prompt "<full prompt text>"
//
// Writes public/images/blog-<slug>.png. Exits 0 on any success (including
// placeholder); prints "FALLBACK: placeholder" so the caller can log it.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : undefined;
}

const slug = arg("slug");
const promptFile = arg("prompt-file");
const promptArg = arg("prompt");
if (!slug || (!promptFile && !promptArg)) {
  console.error("Usage: node scripts/gen-blog-image.mjs --slug <slug> (--prompt-file <path> | --prompt <text>)");
  process.exit(1);
}
const prompt = promptArg ?? fs.readFileSync(path.resolve(root, promptFile), "utf8").trim();
const outPath = path.join(root, "public/images", `blog-${slug}.png`);

const env = fs.readFileSync(path.join(root, ".env.local"), "utf8");
const googleKey = env.match(/^GOOGLE_API_KEY=(.+)$/m)?.[1]?.trim();
const openaiKey = env.match(/^OPENAI_API_KEY=(.+)$/m)?.[1]?.trim();

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function writeImage(base64) {
  fs.writeFileSync(outPath, Buffer.from(base64, "base64"));
  const size = fs.statSync(outPath).size;
  if (size < 10_000) throw new Error(`Output suspiciously small (${size} bytes)`);
  return size;
}

async function tryGemini() {
  if (!googleKey) throw new Error("GOOGLE_API_KEY missing in .env.local");
  const res = await fetch(
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image-preview:generateContent",
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": googleKey },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: { responseModalities: ["IMAGE", "TEXT"] },
      }),
    }
  );
  if (!res.ok) throw new Error(`Gemini API ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const data = await res.json();
  const imgPart = (data?.candidates?.[0]?.content?.parts ?? []).find((p) => p.inlineData?.data);
  if (!imgPart) throw new Error("No image in Gemini response: " + JSON.stringify(data).slice(0, 300));
  return writeImage(imgPart.inlineData.data);
}

async function tryOpenAI() {
  if (!openaiKey) throw new Error("OPENAI_API_KEY missing in .env.local");
  const res = await fetch("https://api.openai.com/v1/images/generations", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${openaiKey}` },
    body: JSON.stringify({ model: "gpt-image-1", prompt, size: "1536x1024", n: 1 }),
  });
  if (!res.ok) throw new Error(`OpenAI API ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const data = await res.json();
  const b64 = data?.data?.[0]?.b64_json;
  if (!b64) throw new Error("No image in OpenAI response");
  return writeImage(b64);
}

// 1. Gemini with retry
for (const [attempt, delay] of [[1, 0], [2, 8000]]) {
  try {
    if (delay) await sleep(delay);
    const size = await tryGemini();
    console.log(`Wrote ${outPath} (${size} bytes) via Gemini, attempt ${attempt}`);
    process.exit(0);
  } catch (err) {
    console.error(`Gemini attempt ${attempt} failed: ${err.message}`);
  }
}

// 2. OpenAI fallback
try {
  const size = await tryOpenAI();
  console.log(`Wrote ${outPath} (${size} bytes) via OpenAI fallback`);
  process.exit(0);
} catch (err) {
  console.error(`OpenAI fallback failed: ${err.message}`);
}

// 3. Branded placeholder — the post still ships with an on-brand image
try {
  fs.copyFileSync(path.join(root, "public/images/blog-placeholder.png"), outPath);
  console.log(`FALLBACK: placeholder copied to ${outPath} — regenerate a real image later`);
  process.exit(0);
} catch (err) {
  console.error(`Placeholder copy failed: ${err.message}`);
  process.exit(1);
}
