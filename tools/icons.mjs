#!/usr/bin/env node
// Converts Reseal-js's icon set (public/js/core/icons.js: 24×24 SVG markup, stroke 1.8, "F:" for
// filled shapes) into zui.Icon path data: src/client/icons.zig.
//
//   node tools/icons.mjs [path/to/icons.js]      (Node 22, no packages)
//
// <circle>, <ellipse> and <rect rx> become arcs; small dots drawn filled inside a stroked icon
// (class="f") become tiny stroked circles of the same outer size, since a zui icon is either
// stroked or filled as a whole.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const src = path.resolve(process.argv[2] || path.join(here, '../../Reseal-js/public/js/core/icons.js'));
const text = fs.readFileSync(src, 'utf8');
const start = text.indexOf('const I = {');
const end = text.indexOf('\n};', start);
// The object literal is plain data (strings only).
const I = new Function(`return ${text.slice(start + 'const I = '.length, end + 3)}`)();

const STROKE = 1.8;
const num = (x) => Number(Number(x).toFixed(3)).toString();
const circle = (cx, cy, r) => `M${num(cx - r)} ${num(cy)}a${num(r)} ${num(r)} 0 1 0 ${num(2 * r)} 0a${num(r)} ${num(r)} 0 1 0 ${num(-2 * r)} 0Z`;
const ellipse = (cx, cy, rx, ry) => `M${num(cx - rx)} ${num(cy)}a${num(rx)} ${num(ry)} 0 1 0 ${num(2 * rx)} 0a${num(rx)} ${num(ry)} 0 1 0 ${num(-2 * rx)} 0Z`;
function rect(x, y, w, h, rx = 0) {
  if (!rx) return `M${num(x)} ${num(y)}h${num(w)}v${num(h)}h${num(-w)}Z`;
  const r = Math.min(rx, w / 2, h / 2);
  return `M${num(x + r)} ${num(y)}h${num(w - 2 * r)}a${num(r)} ${num(r)} 0 0 1 ${num(r)} ${num(r)}v${num(h - 2 * r)}a${num(r)} ${num(r)} 0 0 1 ${num(-r)} ${num(r)}h${num(-(w - 2 * r))}a${num(r)} ${num(r)} 0 0 1 ${num(-r)} ${num(-r)}v${num(-(h - 2 * r))}a${num(r)} ${num(r)} 0 0 1 ${num(r)} ${num(-r)}Z`;
}
const attrs = (el) => Object.fromEntries([...el.matchAll(/([\w-]+)="([^"]*)"/g)].map(m => [m[1], m[2]]));

function convert(markup) {
  if (markup.startsWith('F:')) return { fill: true, paths: [markup.slice(2).trim()] };
  if (!markup.startsWith('<')) return { fill: false, paths: [markup.trim()] };
  const paths = [];
  for (const m of markup.matchAll(/<(path|circle|rect|ellipse)\b([^>]*)\/?>/g)) {
    const a = attrs(m[2]);
    const dot = a.class === 'f';
    switch (m[1]) {
      case 'path': paths.push(a.d.trim()); break;
      case 'circle': {
        const r = Number(a.r);
        // A filled dot of radius r = a stroked circle whose outer edge is at r.
        paths.push(circle(Number(a.cx), Number(a.cy), dot ? Math.max(0.12, r - STROKE / 2) : r));
        break;
      }
      case 'ellipse': paths.push(ellipse(Number(a.cx), Number(a.cy), Number(a.rx), Number(a.ry))); break;
      case 'rect': {
        const [x, y, w, h] = ['x', 'y', 'width', 'height'].map(k => Number(a[k] || 0));
        if (dot) paths.push(rect(x + STROKE / 2, y + STROKE / 2, Math.max(0.2, w - STROKE), Math.max(0.2, h - STROKE), Math.max(0, Number(a.rx || 0) - STROKE / 2)));
        else paths.push(rect(x, y, w, h, Number(a.rx || 0)));
        break;
      }
    }
  }
  return { fill: false, paths };
}

/** The same path drawn mirrored left to right (x -> 24 - x), for arrows in right-to-left languages. */
function mirror(d) {
  let i = 0;
  const out = [];
  const ws = () => { while (i < d.length && /[\s,]/.test(d[i])) i++; };
  const num = () => {
    ws();
    const m = /^[-+]?(\d+\.?\d*|\.\d+)(e[-+]?\d+)?/i.exec(d.slice(i));
    if (!m) return null;
    i += m[0].length;
    return Number(m[0]);
  };
  const flag = () => { ws(); const c = d[i++]; return c === '1' ? 1 : 0; };
  let cmd = null;
  while (true) {
    ws();
    if (i >= d.length) break;
    if (/[a-zA-Z]/.test(d[i])) cmd = d[i++];
    else if (!cmd) break;
    const abs = cmd === cmd.toUpperCase();
    const X = (x) => (abs ? 24 - x : -x);
    const c = cmd.toUpperCase();
    const args = [];
    const take = (n) => { for (let k = 0; k < n; k++) { const v = num(); if (v === null) return false; args.push(v); } return true; };
    if (c === 'Z') { out.push(cmd); cmd = null; continue; }
    if (c === 'A') {
      const rx = num(); if (rx === null) break;
      const ry = num(), rot = num(), large = flag(), sweep = flag(), x = num(), y = num();
      out.push(cmd, rx, ry, -rot, large, 1 - sweep, X(x), y);
    } else if (c === 'H') { if (!take(1)) break; out.push(cmd, X(args[0])); }
    else if (c === 'V') { if (!take(1)) break; out.push(cmd, args[0]); }
    else {
      const n = { M: 2, L: 2, T: 2, Q: 4, S: 4, C: 6 }[c];
      if (!take(n)) break;
      out.push(cmd, ...args.map((v, k) => (k % 2 === 0 ? X(v) : v)));
    }
    if (c === 'M') cmd = abs ? 'L' : 'l';
  }
  return out.map((v) => (typeof v === 'number' ? num3(v) : v)).join(' ');
}
const num3 = (x) => Number(x.toFixed(3)).toString();
// Arrows the web app flips in right-to-left languages (.icon.flip, the send button).
const MIRRORED = ['back', 'forwardArrow', 'chevronRight', 'send'];

const KEYWORDS = new Set(['align', 'and', 'anyframe', 'anytype', 'asm', 'break', 'callconv', 'catch', 'comptime', 'const', 'continue', 'defer', 'else', 'enum', 'errdefer', 'error', 'export', 'extern', 'fn', 'for', 'if', 'inline', 'noalias', 'noinline', 'nosuspend', 'opaque', 'or', 'orelse', 'packed', 'pub', 'resume', 'return', 'linksection', 'struct', 'suspend', 'switch', 'test', 'threadlocal', 'try', 'union', 'unreachable', 'var', 'volatile', 'while']);
const ident = (name) => (KEYWORDS.has(name) ? `@"${name}"` : name);

let out = `//! Reseal's icons, generated by tools/icons.mjs from Reseal-js public/js/core/icons.js. Do not edit.
//! 24×24, stroke ${STROKE} with round caps (as the web app's .icon class); "fill" icons are solid.

const zui = @import("zui");
const Icon = zui.Icon;

`;
const names = Object.keys(I);
for (const name of names) {
  const { fill, paths } = convert(I[name]);
  const list = paths.map(p => JSON.stringify(p)).join(', ');
  out += `pub const ${ident(name)}: Icon = .{ .paths = &.{ ${list} }${fill ? ', .fill = true' : `, .stroke = ${STROKE}`} };\n`;
}
for (const name of MIRRORED) {
  const { fill, paths } = convert(I[name]);
  const list = paths.map(p => JSON.stringify(mirror(p))).join(', ');
  out += `pub const ${name}_rtl: Icon = .{ .paths = &.{ ${list} }${fill ? ', .fill = true' : `, .stroke = ${STROKE}`} };\n`;
}
const dest = path.join(here, '../src/client/icons.zig');
fs.writeFileSync(dest, out);
console.log(`wrote ${names.length} icons to ${path.relative(process.cwd(), dest)}`);
