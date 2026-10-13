#!/usr/bin/env node
// Ports Reseal-js's Arabic dictionary (public/js/i18n/ar.js) to Lassan's flat
// {"English": "translation"} format: src/client/locales/ar.json.
//
//   node tools/i18n-ar.mjs [path/to/ar.js]     (Node 22, no packages)
//
// Plural entries are functions of n in ar.js. A flat file holds strings only, so each one becomes
// six keys, "<English other form>|zero", "|one", "|two", "|few", "|many", "|other" (Arabic's CLDR
// categories); the app's tn() picks the right one (src/client/fmt.zig).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const src = path.resolve(process.argv[2] || path.join(here, '../../Reseal-js/public/js/i18n/ar.js'));
const dict = (await import(pathToFileURL(src).href)).default;

// One sample n per category: zero, one, two, few (3-10), many (11-99), other (100).
const samples = { zero: 0, one: 1, two: 2, few: 3, many: 11, other: 100 };
const out = {};
let plurals = 0;
for (const [key, value] of Object.entries(dict)) {
  if (typeof value === 'string') out[key] = value;
  else if (typeof value === 'function') {
    plurals++;
    for (const [cat, n] of Object.entries(samples)) out[`${key}|${cat}`] = value(n);
  }
}
const dest = path.join(here, '../src/client/locales/ar.json');
fs.mkdirSync(path.dirname(dest), { recursive: true });
// Keys the Zig app adds (screens the web app does not have) are kept.
let extra = {};
const extraPath = path.join(here, '../src/client/locales/ar.extra.json');
if (fs.existsSync(extraPath)) extra = JSON.parse(fs.readFileSync(extraPath, 'utf8'));
fs.writeFileSync(dest, JSON.stringify({ ...out, ...extra }, null, 2) + '\n');
console.log(`wrote ${Object.keys(out).length} strings (${plurals} plurals) + ${Object.keys(extra).length} extra to ${path.relative(process.cwd(), dest)}`);
