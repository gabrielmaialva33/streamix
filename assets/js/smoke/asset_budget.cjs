const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");

const staticRoot = path.resolve(__dirname, "../../../priv/static/assets");
const jsRoot = path.join(staticRoot, "js");
const appEntry = path.join(jsRoot, "app.js");
const cssEntry = path.join(staticRoot, "css/app.css");

const budgets = {
  cssGzip: Number(process.env.ASSET_BUDGET_CSS_GZIP || 36 * 1024),
  eagerJsGzip: Number(process.env.ASSET_BUDGET_EAGER_JS_GZIP || 64 * 1024),
  totalJsGzip: Number(process.env.ASSET_BUDGET_TOTAL_JS_GZIP || 640 * 1024),
  reachableJsFiles: Number(process.env.ASSET_BUDGET_REACHABLE_JS_FILES || 34),
};

function gzipSize(file) {
  return zlib.gzipSync(fs.readFileSync(file), { level: 9 }).byteLength;
}

function importSpecifiers(file) {
  const source = fs.readFileSync(file, "utf8");
  const specifiers = [];
  const patterns = [
    { kind: "dynamic", regex: /\bimport\(\s*["']\.\/([^"']+\.js)["']\s*\)/g },
    { kind: "static", regex: /\bfrom\s*["']\.\/([^"']+\.js)["']/g },
    { kind: "static", regex: /\bimport\s*["']\.\/([^"']+\.js)["']/g },
  ];

  for (const { kind, regex } of patterns) {
    for (const match of source.matchAll(regex)) {
      specifiers.push({ kind, file: path.resolve(path.dirname(file), match[1]) });
    }
  }

  return specifiers;
}

function reachableFiles({ includeDynamic }) {
  const visited = new Set();
  const pending = [appEntry];

  while (pending.length > 0) {
    const file = pending.pop();
    if (visited.has(file)) continue;

    assert.ok(file.startsWith(`${jsRoot}${path.sep}`) || file === appEntry);
    assert.ok(fs.existsSync(file), `referenced asset is missing: ${path.relative(staticRoot, file)}`);
    visited.add(file);

    for (const dependency of importSpecifiers(file)) {
      if (includeDynamic || dependency.kind === "static") pending.push(dependency.file);
    }
  }

  return [...visited];
}

function totalGzip(files) {
  return files.reduce((total, file) => total + gzipSize(file), 0);
}

function main() {
  assert.ok(fs.existsSync(appEntry), "run mix assets.deploy before checking asset budgets");
  assert.ok(fs.existsSync(cssEntry), "compiled CSS is missing");

  const eagerFiles = reachableFiles({ includeDynamic: false });
  const allFiles = reachableFiles({ includeDynamic: true });
  const report = {
    cssGzip: gzipSize(cssEntry),
    eagerJsGzip: totalGzip(eagerFiles),
    eagerJsFiles: eagerFiles.length,
    totalJsGzip: totalGzip(allFiles),
    reachableJsFiles: allFiles.length,
  };

  console.log(JSON.stringify({ budgets, report }, null, 2));

  assert.ok(report.cssGzip <= budgets.cssGzip, "CSS gzip budget exceeded");
  assert.ok(report.eagerJsGzip <= budgets.eagerJsGzip, "eager JS gzip budget exceeded");
  assert.ok(report.totalJsGzip <= budgets.totalJsGzip, "total reachable JS gzip budget exceeded");
  assert.ok(
    report.reachableJsFiles <= budgets.reachableJsFiles,
    "reachable JS file-count budget exceeded",
  );
}

main();
