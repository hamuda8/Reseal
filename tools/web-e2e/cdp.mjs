// Headless Chrome over the DevTools protocol, one object per tab.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

export async function launch(dir, port = 9350, extra = []) {
  const chrome = spawn('C:/Program Files/Google/Chrome/Application/chrome.exe', ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${path.resolve(dir)}/profile`, '--window-size=1280,800', '--no-first-run',
    '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required', ...extra, 'about:blank'], { stdio: 'ignore' });
  for (let i = 0; i < 150; i++) {
    await sleep(200);
    try { await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch {}
  }
  return { chrome, port, kill: () => chrome.kill() };
}

export async function tab(browser, out, { width = 1280, height = 800, mobile = false, dark = false, name = 'tab' } = {}) {
  const target = await (await fetch(`http://127.0.0.1:${browser.port}/json/new?about:blank`, { method: 'PUT' })).json();
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
  let seq = 0;
  const pending = new Map();
  const logs = [];
  const events = [];
  ws.addEventListener('message', (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    if (m.method) events.push(m);
    if (m.method === 'Runtime.consoleAPICalled') logs.push(m.params.args.map(a => a.value ?? a.description).join(' '));
    if (m.method === 'Log.entryAdded') logs.push('LOG ' + m.params.entry.text);
    if (m.method === 'Network.responseReceived' && m.params.response.url.includes('/api') && m.params.response.status >= 400) logs.push('NET ' + m.params.response.status + ' ' + m.params.response.url.split('/api')[1]);
    if (m.method === 'Runtime.exceptionThrown') logs.push('EXCEPTION ' + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
  });
  const send = (method, params = {}) => new Promise(r => { const id = ++seq; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
  const t = { name, logs, send, events };
  t.waitEvent = async (method, ms = 5000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const i = events.findIndex(e => e.method === method); if (i >= 0) return events.splice(i, 1)[0]; await sleep(100); } return null; };
  t.evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result?.result?.value;
  t.shot = async (file) => { const r = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(out, `${file}.png`), Buffer.from(r.result.data, 'base64')); console.log('  shot', file); };
  t.click = async (x, y) => {
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
  };
  t.texts = () => t.evaluate(`[...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && d.textContent).map(d => d.textContent)`);
  t.hasText = async (s) => (await t.texts())?.some(x => x.includes(s));
  t.waitText = async (s, ms = 8000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (await t.hasText(s)) return true; await sleep(250); } return false; };
  t.centerOfText = (label, exact = true) => t.evaluate(`(() => { const els = [...document.querySelectorAll('div')].filter(d => ![...d.children].some(k => k.tagName === 'DIV') && (${exact} ? d.textContent === ${JSON.stringify(label)} : d.textContent.includes(${JSON.stringify(label)}))); const top = (e) => { const r = e.getBoundingClientRect(); if (!r.width) return false; const h = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2); return h && (h === e || e.contains(h) || h.contains(e)); }; let el = els.find(top); if (!el) { el = els.find(e => e.getBoundingClientRect().width > 0) || els[0]; if (el) el.scrollIntoView({ block: 'center' }); } if (!el) return null; const r = el.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
  t.clickText = async (label, exact = true) => {
    const p = await t.centerOfText(label, exact);
    if (!p) throw new Error(`${name}: no text ${label}`);
    await t.click(p[0], p[1]);
    await sleep(500);
  };
  /** Clicks the pressable box holding the n-th svg icon whose path starts with `d` (icon buttons). */
  t.clickAt = async (x, y) => { await t.click(x, y); await sleep(400); };
  t.typeIn = async (placeholder, text) => {
    const p = await t.evaluate(`(() => { const el = [...document.querySelectorAll('input,textarea')].find(i => i.placeholder === ${JSON.stringify(placeholder)}); if (!el) return null; el.scrollIntoView({ block: 'center' }); const r = el.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
    if (!p) throw new Error(`${name}: no input ${placeholder}`);
    await t.click(p[0], p[1]);
    await t.evaluate(`(() => { const el = document.activeElement; if (el && el.select) el.select(); })()`);
    await send('Input.insertText', { text });
    await sleep(250);
  };
  t.key = async (k) => {
    const code = { Enter: 13, Escape: 27 }[k] || 0;
    await send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code: k, windowsVirtualKeyCode: code });
    await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code: k, windowsVirtualKeyCode: code });
  };
  t.go = async (url, wait = 3500) => { await send('Page.navigate', { url }); await sleep(wait); };
  t.close = () => fetch(`http://127.0.0.1:${browser.port}/json/close/${target.id}`).catch(() => {});
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Network.enable');
  await send('Log.enable');
  await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: mobile ? 2 : 1, mobile });
  if (mobile) await send('Emulation.setTouchEmulationEnabled', { enabled: false });
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: dark ? 'dark' : 'light' }] });
  return t;
}
