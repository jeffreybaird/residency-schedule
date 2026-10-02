const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");

const root = path.resolve(__dirname, "../..");
const chrome = process.env.CHROME_BIN || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

function files(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const filename = path.join(directory, entry.name);
    return entry.isDirectory() ? files(filename) : /\.(ex|heex)$/.test(filename) ? [filename] : [];
  });
}

// Exercise the actual class strings in templates and dynamic class helpers.
// Only neutral UI surfaces/text are selected; rotation colors get a separate check.
const samples = files(path.join(root, "lib/residency_schedule_web"))
  .filter(file => /\/(live|components|controllers)\//.test(file))
  .flatMap(file => [...fs.readFileSync(file, "utf8").matchAll(/"([^"\n]*)"/g)]
    .filter(match => /(?:^| )bg-(?:white|gray-\d+)\b/.test(match[1]) || /(?:^| )text-gray-(?:[5-9]00)\b/.test(match[1]) || /(?:^| )bg-(?:blue|red|amber|yellow|green|emerald|indigo|violet)-(?:50|100)\b/.test(match[1]))
    .filter(match => !/\b(?:bg-(?!gray|white)\w+-(?:[2-9]00)|text-white)\b/.test(match[1]))
    .map(match => ({ source: path.relative(root, file), classes: match[1] })));

const controls = files(path.join(root, "lib/residency_schedule_web"))
  .flatMap(file => [...fs.readFileSync(file, "utf8").matchAll(/<(input|select)\b[^>]*?class="([^"]+)"[^>]*>/g)]
    .map(match => ({ source: path.relative(root, file), classes: match[2], tag: match[1] })));
samples.push(...controls);

test("actual app neutral classes produce dark surfaces and readable text, preserving light colors", () => {
  assert.ok(fs.existsSync(chrome), "Install Chrome or provide CHROME_BIN to run computed CSS regressions");
  assert.ok(samples.length > 100, "Expected representative classes throughout the real app templates");
  for (const area of ["layouts/root", "calendar_live", "schedule_live", "compare_live", "auth_html", "admin_live", "builder_live", "edit_live", "chat_live"]) {
    assert.ok(samples.some(sample => sample.source.includes(area)), `Missing actual ${area} coverage`);
  }
  const css = fs.readFileSync(path.join(root, "priv/static/assets/css/app.css"), "utf8");
  const tourSource = fs.readFileSync(path.join(root, "assets/js/tour.js"), "utf8");
  const welcomeText = JSON.parse(tourSource.match(/text: ("(?:[^"\\]|\\.)*")/)?.[1]);
  const rotationSource = fs.readFileSync(path.join(root, "lib/residency_schedule/rotations/rotations.ex"), "utf8");
  const badges = [...rotationSource.matchAll(/"(bg-[\w-]+ text-[\w-]+)"/g)].map(match => match[1]);
  assert.ok(badges.length > 10);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "residency-palette-test-"));
  const filename = path.join(directory, "palette.html");
  const escape = value => value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
  const items = samples.map((sample, index) => {
    const attributes = `data-sample="${index}" class="${escape(sample.classes)}"`;
    if (sample.tag === "input") return `<input ${attributes} value="Email">`;
    if (sample.tag === "select") return `<select ${attributes}><option>Year</option></select>`;
    return `<div ${attributes}>Readable schedule content</div>`;
  }).join("");
  const badgeItems = badges.map((classes, index) => `<span data-badge="${index}" class="${escape(classes)}">Rotation</span>`).join("");
  fs.writeFileSync(filename, `<!doctype html><html data-theme="light"><head><style>${css}</style><style>*, *::before, *::after { transition: none !important; animation: none !important; }</style></head><body>
    <section class="bg-white dark:bg-gray-900 text-gray-900 dark:text-gray-100">${items}</section>
    ${badgeItems}<div class="shepherd-element shepherd-enabled"><div class="shepherd-header"><h2 class="shepherd-title">Tour</h2></div><div class="shepherd-text">${welcomeText}</div><div class="shepherd-footer"><button id="tour-primary" class="shepherd-button">Next</button><button id="tour-secondary" class="shepherd-button shepherd-button-secondary">Back</button></div></div>
    <button id="tour-continue-btn">Continue Tour</button>
    <div class="chat-markdown"><code>schedule</code></div><input id="plain-input" value="Email"><select id="plain-select"><option>Year</option></select>
    <pre id="result"></pre><script>
      const samples = ${JSON.stringify(samples)};
      const failures = [];
      const rgb = color => { const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1; const context = canvas.getContext('2d'); context.fillStyle = color; context.fillRect(0,0,1,1); return [...context.getImageData(0,0,1,1).data].slice(0,3); };
      const luminance = color => rgb(color).map(c => { c /= 255; return c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4; }).reduce((sum,c,i) => sum + c * [.2126,.7152,.0722][i],0);
      const contrast = (a,b) => (Math.max(luminance(a),luminance(b)) + .05) / (Math.min(luminance(a),luminance(b)) + .05);
      const composite = (foreground, background) => { const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1; const context = canvas.getContext('2d'); context.fillStyle = background; context.fillRect(0,0,1,1); context.fillStyle = foreground; context.fillRect(0,0,1,1); return 'rgb(' + [...context.getImageData(0,0,1,1).data].slice(0,3).join(',') + ')'; };
      const style = element => { const s = getComputedStyle(element); return {background:s.backgroundColor, color:s.color}; };
      const lightBadges = [...document.querySelectorAll('[data-badge]')].map(style);
      const lightSamples = [...document.querySelectorAll('[data-sample]')].map(style);
      document.documentElement.dataset.theme = 'dark';
      document.querySelectorAll('[data-sample]').forEach((element,i) => {
        const sample = samples[i], dark = style(element), light = lightSamples[i];
        if (/(^| )bg-(white|gray-[0-9]+)\\b/.test(sample.classes)) {
          if (luminance(dark.background) > .2) failures.push(sample.source + ': bright dark surface ' + sample.classes);
          if (luminance(light.background) < luminance(dark.background) + .1) failures.push(sample.source + ': light neutral surface no longer distinguishable ' + sample.classes);
        }
        const background = dark.background === 'rgba(0, 0, 0, 0)' ? 'rgb(17, 24, 39)' : dark.background;
        if (/(^| )text-gray-[5-9]00\\b/.test(sample.classes) && contrast(dark.color, background) < 4.5) failures.push(sample.source + ': unreadable dark text ' + sample.classes);
        if (/(^| )bg-(blue|red|amber|yellow|green|emerald|indigo|violet)-(50|100)\\b/.test(sample.classes)) {
          if (luminance(dark.background) > .2) failures.push(sample.source + ': bright dark status surface ' + sample.classes);
          if (contrast(dark.color, background) < 4.5) failures.push(sample.source + ': unreadable dark status text ' + sample.classes);
        }
      });
      document.querySelectorAll('[data-badge]').forEach((element,i) => {
        const dark = style(element), light = lightBadges[i];
        if (JSON.stringify(dark) !== JSON.stringify(light)) failures.push('Rotation badge palette changed across themes: ' + element.className);
        if (/text-gray-(700|800|900)/.test(element.className) && contrast(dark.color, dark.background) < 4.5) failures.push('Rotation badge lost readable neutral foreground: ' + element.className);
      });
      for (const selector of ['.shepherd-element','.shepherd-header','.shepherd-title','.shepherd-text','.shepherd-text em','.chat-markdown code','#plain-input','#plain-select']) {
        const value = style(document.querySelector(selector));
        if (value.background !== 'rgba(0, 0, 0, 0)' && luminance(value.background) > .2) failures.push(selector + ': bright dark background');
        if (contrast(value.color, 'rgb(17, 24, 39)') < 4.5) failures.push(selector + ': unreadable dark foreground');
      }
      for (const selector of ['#tour-primary','#tour-secondary','#tour-continue-btn','.chat-markdown code']) {
        const value = style(document.querySelector(selector));
        if (contrast(composite(value.color, value.background), value.background) < 4.5) failures.push(selector + ': insufficient contrast against own background');
      }
      document.querySelector('#result').textContent = JSON.stringify(failures);
    </script></body></html>`);
  try {
    const result = spawnSync(chrome, ["--headless", "--no-sandbox", "--disable-gpu", "--no-first-run", `--user-data-dir=${directory}/profile`, "--dump-dom", `file://${filename}`], { encoding: "utf8", timeout: 30000, maxBuffer: 8 * 1024 * 1024 });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
    const encoded = result.stdout.match(/<pre id="result">([\s\S]*?)<\/pre>/)?.[1];
    assert.ok(encoded, "Chrome did not execute computed-style fixture");
    const failures = JSON.parse(encoded.replaceAll("&gt;", ">").replaceAll("&lt;", "<").replaceAll("&amp;", "&"));
    assert.deepEqual(failures, [], failures.slice(0, 15).join("\n"));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
