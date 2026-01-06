#!/usr/bin/env node
/**
 * Fix Tizen index.html to only use legacy build
 *
 * Problem: Vite's legacy plugin creates both modern (type="module") and legacy (nomodule) scripts.
 * On Tizen (file:// protocol), both scripts run causing double initialization.
 *
 * Solution: Remove modern modules and only keep legacy build for Tizen.
 */

import fs from 'fs';
import path from 'path';

const DIST_TIZEN = path.resolve(process.cwd(), 'dist/tizen');
const INDEX_HTML = path.join(DIST_TIZEN, 'index.html');

function fixTizenHtml() {
  console.log('Fixing Tizen index.html for legacy-only build...');

  if (!fs.existsSync(INDEX_HTML)) {
    console.error('Error: dist/tizen/index.html not found. Run build:tizen first.');
    process.exit(1);
  }

  let html = fs.readFileSync(INDEX_HTML, 'utf-8');

  // Remove modern module scripts (type="module")
  // Keep only legacy scripts (nomodule)

  // Remove polyfills module script
  html = html.replace(/<script type="module" crossorigin src="\.\/assets\/polyfills[^"]*\.js"><\/script>\s*/g, '');

  // Remove main index module script
  html = html.replace(/<script type="module" crossorigin src="\.\/assets\/index[^"]*\.js"><\/script>\s*/g, '');

  // Remove Vite's modern browser detection scripts
  html = html.replace(/<script type="module">import\.meta\.url[^<]*<\/script>\s*/g, '');
  html = html.replace(/<script type="module">!function\(\)\{if\(window\.__vite_is_modern_browser[^<]*<\/script>\s*/g, '');

  // Remove nomodule attribute from legacy scripts (so they always run)
  html = html.replace(/nomodule crossorigin/g, 'crossorigin');
  html = html.replace(/<script nomodule>/g, '<script>');

  // Also remove the inline nomodule detection script
  html = html.replace(/<script>!function\(\)\{var e=document,t=e\.createElement[^<]*<\/script>\s*/g, '');

  // Fix legacy entry to use direct script loading instead of System.import
  // Replace the System.import inline with a simple script tag
  html = html.replace(
    /<script crossorigin id="vite-legacy-entry" data-src="([^"]+)">[^<]*<\/script>/,
    '<script crossorigin id="vite-legacy-entry" src="$1"></script>'
  );

  fs.writeFileSync(INDEX_HTML, html);
  console.log('Fixed! Tizen index.html now uses legacy-only build.');

  // Verify the fix
  const fixed = fs.readFileSync(INDEX_HTML, 'utf-8');
  const moduleCount = (fixed.match(/type="module"/g) || []).length;
  const legacyCount = (fixed.match(/legacy/gi) || []).length;

  console.log(`  - Module scripts removed: ${moduleCount === 0 ? 'YES' : 'NO (still has ' + moduleCount + ')'}`);
  console.log(`  - Legacy scripts present: ${legacyCount > 0 ? 'YES' : 'NO'}`);
}

fixTizenHtml();
