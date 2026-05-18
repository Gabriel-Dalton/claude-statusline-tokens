// Walk the DOM and report any element whose right edge extends past the
// viewport. Helps identify which specific node is forcing horizontal scroll.

import { chromium } from "playwright";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const htmlPath = path.resolve(__dirname, "..", "index.html");

const viewports = [
  { name: "320", width: 320 },
  { name: "1024", width: 1024 },
];

const browser = await chromium.launch();

for (const vp of viewports) {
  const ctx = await browser.newContext({ viewport: { width: vp.width, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(pathToFileURL(htmlPath).toString(), { waitUntil: "networkidle" });
  await page.evaluate(() => document.fonts?.ready);

  const offenders = await page.evaluate((vw) => {
    // Walk up from each element and ask "does any ancestor clip horizontal
    // overflow?" If so, this element's intrinsic position doesn't contribute
    // to documentElement.scrollWidth — skip it.
    const clipsX = (el) => {
      const s = getComputedStyle(el);
      return s.overflowX === "hidden" || s.overflowX === "clip" ||
             s.overflowX === "scroll" || s.overflowX === "auto";
    };
    const isClippedByAncestor = (el) => {
      for (let a = el.parentElement; a; a = a.parentElement) {
        if (clipsX(a)) return true;
      }
      return false;
    };

    const out = [];
    for (const el of document.querySelectorAll("*")) {
      const r = el.getBoundingClientRect();
      if (r.right > vw + 0.5 && r.width > 0 && !isClippedByAncestor(el)) {
        out.push({
          tag: el.tagName.toLowerCase(),
          cls: (el.className?.toString() || "").slice(0, 60),
          id: el.id || "",
          left: Math.round(r.left),
          right: Math.round(r.right),
          width: Math.round(r.width),
          overflow: Math.round(r.right - vw),
          text: (el.textContent || "").trim().slice(0, 60).replace(/\s+/g, " "),
        });
      }
    }
    out.sort((a, b) => b.overflow - a.overflow);
    return out.slice(0, 12);
  }, vp.width);

  console.log(`\nViewport ${vp.width}:`);
  for (const o of offenders) {
    console.log(`  +${o.overflow}px  <${o.tag}${o.cls ? "." + o.cls.split(" ").join(".") : ""}${o.id ? "#" + o.id : ""}>  L${o.left} R${o.right} W${o.width}  "${o.text}"`);
  }

  await ctx.close();
}

await browser.close();
