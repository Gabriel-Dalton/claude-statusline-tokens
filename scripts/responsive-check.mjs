// One-shot Playwright runner that screenshots index.html at multiple
// viewport widths so we can eyeball the responsive layout without spinning
// up a real dev server. Saves PNGs to docs/img/responsive/.

import { chromium } from "playwright";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs/promises";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const htmlPath = path.join(repoRoot, "index.html");
const outDir = path.join(repoRoot, "docs", "img", "responsive");
await fs.mkdir(outDir, { recursive: true });

const viewports = [
  { name: "320-iphone-se",   width: 320,  height: 720 },
  { name: "375-iphone",      width: 375,  height: 800 },
  { name: "414-iphone-plus", width: 414,  height: 896 },
  { name: "768-ipad",        width: 768,  height: 1024 },
  { name: "1024-desktop",    width: 1024, height: 800 },
];

const browser = await chromium.launch();
const failures = [];

for (const vp of viewports) {
  const ctx = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    deviceScaleFactor: 2,
  });
  const page = await ctx.newPage();
  const fileUrl = pathToFileURL(htmlPath).toString();
  await page.goto(fileUrl, { waitUntil: "networkidle" });

  // Wait for Google Fonts to settle so screenshots are stable.
  await page.evaluate(() => document.fonts ? document.fonts.ready : null);

  // Flag any horizontal scrollbar — a strong signal of responsive breakage.
  const overflow = await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
  }));
  const hasHScroll = overflow.scrollWidth > overflow.clientWidth + 1;
  if (hasHScroll) {
    failures.push(`${vp.name}: H-scroll (scrollWidth=${overflow.scrollWidth} > clientWidth=${overflow.clientWidth})`);
  }

  const outPath = path.join(outDir, `${vp.name}.png`);
  await page.screenshot({ path: outPath, fullPage: true });
  console.log(`  ${vp.name.padEnd(20)} ${vp.width}x${vp.height}  ${hasHScroll ? "H-SCROLL" : "ok"}  -> ${path.relative(repoRoot, outPath)}`);

  await ctx.close();
}

await browser.close();

if (failures.length) {
  console.error("\nFAIL:");
  for (const f of failures) console.error("  " + f);
  process.exit(1);
}
console.log("\nAll viewports rendered without horizontal scroll.");
