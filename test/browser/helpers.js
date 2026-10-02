'use strict';

const { expect } = require('@playwright/test');
const path = require('path');

const PASSWORD = 'admin';
const SCREENSHOTS = path.join(__dirname, '..', 'results', 'screenshots');

// The exporter's config and the plugin's ubus object; the package of the exporter, and
// PACKAGE-<collector> of each collector.
const CONFIG = 'prometheus-exporter';
const PACKAGE = 'ucode-prometheus-exporter';

// A login granted luci-base and the app's ACL alone (devenv/services/luci/start.sh).
const APP_USER = { username: 'metrics', password: 'metrics' };

// A login granted the same for reading alone.
const VIEWER = { username: 'viewer', password: 'viewer' };

// The help and error of the hostile test collector (test/fixtures/luci/collectors/hostile.uc).
const HOSTILE = '<img src=x onerror=window.__xss=1>';

const sessions = {};

// A ubus call over uhttpd's JSON-RPC endpoint, as root unless `user` is given.
async function ubus(request, object, method, params, user) {
  const who = user ?? { username: 'root', password: PASSWORD };
  if (sessions[who.username] == null) {
    const login = await call(request, '00000000000000000000000000000000', 'session', 'login', who);
    sessions[who.username] = login.ubus_rpc_session;
  }
  return call(request, sessions[who.username], object, method, params);
}

// The ubus status code and reply, without failing on a refusal.
async function rawCall(request, sid, object, method, params) {
  const res = await request.post('/ubus/', {
    data: { jsonrpc: '2.0', id: 1, method: 'call', params: [sid, object, method, params ?? {}] },
  });
  return res.json();
}

async function call(request, sid, object, method, params) {
  const body = await rawCall(request, sid, object, method, params);
  if (body.error || body.result[0] !== 0)
    throw new Error(`ubus ${object} ${method}: ${JSON.stringify(body)}`);
  return body.result[1];
}

// Whether rpcd refused a call (rawCall's reply) for want of access.
function denied(body) {
  return body.error?.code === -32002 || body.result?.[0] === 6;
}

// The session of a login, for calls that are expected to be refused.
async function sessionOf(request, user) {
  await ubus(request, 'session', 'access', {}, user);
  return sessions[user.username];
}

// Makes the fake procd answer test/fixtures/luci/service/<name>.json; `none` withdraws it.
async function useService(request, name) {
  const res = await ubus(request, 'exporter.fixture', 'service', { name });
  expect(res.ok, `service fixture ${name}`).toBe(true);
}

// Writes the exporter's config from test/fixtures/luci/config/<name>; `default` puts
// back the one the container started with, as the package installed it.
async function useConfig(request, name) {
  const res = await ubus(request, 'exporter.fixture', 'config', { name });
  expect(res.ok, `config ${name}`).toBe(true);
}

// The exporter's config as it is on disk.
async function readConfig(request) {
  return (await ubus(request, 'exporter.fixture', 'read', {})).data;
}

// The sections of a uci file as { name: { '.type', option: value } }.
function sections(file) {
  const out = {};
  for (const block of file.split(/\n(?=config )/)) {
    const head = /^\s*config (\S+)(?: '([^']*)')?/.exec(block);
    if (!head)
      continue;
    const opts = { '.type': head[1] };
    for (const m of block.matchAll(/option (\w+) '([^']*)'/g))
      opts[m[1]] = m[2];
    out[head[2] ?? `@${Object.keys(out).length}`] = opts;
  }
  return out;
}

// Posts LuCI's login form through the page's own request context, which shares the
// browser's cookies, so the page then opens logged in; as root unless `user` is given.
// A page logs in once: LuCI answers a second login of the same session with the page.
async function open(page, route, user) {
  const cookies = await page.context().cookies();
  if (!cookies.some((c) => c.name.startsWith('sysauth'))) {
    const login = await page.request.post('/cgi-bin/luci/', {
      form: { luci_username: user?.username ?? 'root', luci_password: user?.password ?? PASSWORD },
      maxRedirects: 0,
    });
    expect(login.status(), 'LuCI login').toBe(302);
  }
  await page.goto(`/cgi-bin/luci/${route}`);
  await page.locator('#view').waitFor();
  await expect(page.locator('#view .spinning')).toHaveCount(0, { timeout: 20000 });
}

// The settings page, on its Exporter tab: LuCI reopens a page on the tab last shown.
async function openSettings(page, user) {
  await open(page, `admin/services/${CONFIG}`, user);
  await expect(page.locator('#view h2', { hasText: 'Prometheus exporter' })).toBeVisible();
  await expect(page.locator('#view tr[data-collector]').first()).toBeAttached();
  await showTab(page, 'exporter');
}

// Shows a tab of the settings page: exporter or collectors.
async function showTab(page, name) {
  await page.locator(`#view .cbi-tabmenu li[data-tab="${name}"] > a`).click();
  await expect(page.locator(`#view .cbi-tabmenu li[data-tab="${name}"]`)).toHaveClass(/cbi-tab(?!-)/);
}

// LuCI's dialog, as ui.showModal shows it.
function modal(page) {
  return page.locator('#modal_overlay > .modal');
}

// LuCI's Save error dialog, as a refused Save shows it.
function saveError(page) {
  return modal(page).filter({ has: page.locator('h4', { hasText: /^Save error$/ }) });
}

// Answers every call of the exporter's ubus object as uhttpd does while the object is not
// there (rpcd reloading): JSON-RPC error -32000, Object not found. Other calls go through.
async function withoutObject(page) {
  await page.route(/\/ubus\//, async (route) => {
    const body = JSON.parse(route.request().postData() ?? 'null');
    const calls = [].concat(body ?? []);
    const ours = (c) => c?.method === 'call' && c.params?.[1] === CONFIG;
    if (!calls.some(ours))
      return route.continue();
    const res = await route.fetch();
    const replies = [].concat(await res.json());
    const out = calls.map((c) => ours(c)
      ? { jsonrpc: '2.0', id: c.id, error: { code: -32000, message: 'Object not found' } }
      : replies.find((r) => r.id === c.id));
    await route.fulfill({ response: res, json: Array.isArray(body) ? out : out[0] });
  });
}

// Opens the dialog of a collector's options from its row on the Collectors tab.
async function editCollector(page, id) {
  await showTab(page, 'collectors');
  await collectorRow(page, id).getByRole('button', { name: 'Edit', exact: true }).click();
  await expect(modal(page).locator(`.exporter-editor[data-collector="${id}"]`)).toBeVisible();
  return modal(page);
}

// What this page's login has staged in uci and not applied, by config.
async function staged(page) {
  return page.evaluate(async () => {
    const uci = await L.require('uci');
    return uci.changes();
  });
}

async function openStatus(page, user) {
  await open(page, `admin/status/${CONFIG}`, user);
  await expect(page.locator('#view h2', { hasText: 'Prometheus exporter' })).toBeVisible();
}

// A section of a page by its heading.
function section(page, title) {
  return page.locator('#view .cbi-section').filter({ has: page.locator('h3', { hasText: new RegExp(`^${title}$`) }) });
}

function collectorRow(page, id) {
  return page.locator(`#view tr[data-collector="${id}"]`);
}

// The text as written, before a theme's text-transform.
async function text(locator) {
  return locator.evaluate((el) => el.textContent);
}

// A whole page, from the top.
async function screenshot(page, name) {
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(SCREENSHOTS, `${name}.png`), fullPage: true });
}

module.exports = {
  CONFIG, PACKAGE, APP_USER, VIEWER, HOSTILE, ubus, rawCall, denied, sessionOf, useService, useConfig, readConfig, sections, open, openSettings,
  showTab, modal, saveError, withoutObject, editCollector, staged, openStatus, section, collectorRow, text, screenshot,
};
