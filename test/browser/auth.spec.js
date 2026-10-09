const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Basic auth, on the HTTPS & login tab of Services → Prometheus exporter, and compress,
// on its General tab. The password is typed, and handed on Save to the ubus object's
// stage_password, which stages its hash in the login's session, for
// prometheus-exporter-auth, which the page never reads; Save & Apply applies it with the
// rest. Basic auth takes the TLS certificate and key.

// `uhttpd -m secret`, as test/fixtures/luci/auth/auth has it.
const SAVED_HASH = '$1$$ysVNzQc4CTMkp5daOdZ.3/';
const PASSWORD = 'browser-secret';

function field(page, option) {
  return page.locator(`[id="widget.cbid.${h.CONFIG}.main.${option}"]`);
}

function flag(page, option) {
  return page.locator(`[id="cbid.${h.CONFIG}.main.${option}"] input[type="checkbox"]`);
}

async function saveAndApply(page) {
  await page.locator('#view .cbi-page-actions').getByText('Save & Apply', { exact: true }).click();
}

// A refused Save: LuCI's Save error dialog, with what was refused, which is dismissed;
// what was refused stays above the form.
async function refused(page, items) {
  const dialog = h.saveError(page);
  await expect(dialog).toBeVisible();
  await expect(dialog).toContainText('Nothing was saved');
  await expect(dialog.locator('.exporter-line')).toContainText(items);
  await dialog.getByRole('button', { name: 'Dismiss', exact: true }).click();
  await expect(h.modal(page)).toBeHidden();
  await expect(page.locator('#view .alert-message.error .exporter-line')).toContainText(items);
}

async function applied(page) {
  await expect(page.getByText('Configuration changes applied.')).toBeVisible({ timeout: 30000 });
}

async function savedMain(request) {
  return h.sections(await h.readConfig(request)).main;
}

// The hash saved apart, or undefined.
async function savedHash(request) {
  return h.sections(await h.readAuth(request)).main?.auth_password;
}

// The calls of the ubus object's methods the page makes, by method.
function ubusCalls(page) {
  const calls = [];
  page.on('request', (req) => {
    if (req.method() !== 'POST' || !req.url().includes('/ubus'))
      return;
    for (const body of [].concat(JSON.parse(req.postData() ?? 'null') ?? []))
      if (body?.params?.[1] === h.CONFIG)
        calls.push({ method: body.params[2], params: body.params[3] });
  });
  return calls;
}

test.describe('Services → Prometheus exporter: basic auth and compress', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('has a user and a password field for basic auth, and compress on by default', async ({ page }) => {
    await h.openSettings(page);
    await expect(flag(page, 'compress')).toBeChecked();
    await h.showTab(page, 'https');
    await expect(field(page, 'auth_user')).toBeVisible();
    await expect(field(page, 'auth_user')).toHaveValue('');
    await expect(field(page, 'auth_user')).toHaveAttribute('placeholder', 'None');
    // What basic auth takes is said before a Save is refused for it, once: by the tab.
    await expect(page.locator('#view div[data-tab="https"] .cbi-tab-descr')).toHaveText('Basic auth needs HTTPS: set the certificate and key first.');
    await expect(page.locator('[data-name="auth_user"] .cbi-value-description')).toHaveText('With a password, a scrape logs in as this user. Empty for none.');
    await expect(page.locator('[data-name="auth_password"] .cbi-value-description')).toHaveText('Saved as a hash; the password itself is never stored. Empty keeps the saved one.');
    await expect(field(page, 'auth_password')).toHaveValue('');
    await expect(field(page, 'auth_password')).toHaveAttribute('type', 'password');
    await expect(field(page, 'auth_password')).not.toHaveAttribute('placeholder', 'Unchanged');
    await h.screenshot(page, 'settings-auth-empty');
  });

  test('refuses basic auth without the TLS certificate and key, and saves nothing', async ({ page, request }) => {
    const before = await h.readConfig(request);
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'auth_user').fill('prom');
    await field(page, 'auth_password').fill(PASSWORD);
    await expect(field(page, 'auth_user')).toHaveClass(/cbi-input-invalid/);
    await saveAndApply(page);
    await refused(page, [
      'HTTPS & login → Basic auth user: Basic auth user needs HTTPS: set TLS certificate and TLS key, or the password crosses the network in the clear',
    ]);
    expect(await h.readConfig(request)).toBe(before);
    expect(calls.filter((c) => c.method === 'stage_password')).toEqual([]);
    expect(await savedHash(request)).toBeUndefined();
  });

  test('has the ubus object save the hash apart, never the password, and never reads the hash', async ({ page, request }) => {
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'cert').fill('/etc/uhttpd.crt');
    await field(page, 'key').fill('/etc/uhttpd.key');
    await field(page, 'auth_user').fill('prom');
    await field(page, 'auth_password').fill(PASSWORD);
    await saveAndApply(page);
    await applied(page);

    const main = await savedMain(request);
    const hash = await savedHash(request);
    expect([ main.auth_user, main.auth_password ]).toEqual([ 'prom', undefined ]);
    expect(hash).toMatch(/^\$6\$rounds=1000\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$/);
    expect(await h.readConfig(request)).not.toContain(PASSWORD);
    expect(await h.readAuth(request)).not.toContain(PASSWORD);
    expect(calls.filter((c) => c.method === 'stage_password')).toEqual([ { method: 'stage_password', params: { password: PASSWORD } } ]);
    expect(calls.filter((c) => [ 'hash_password', 'set_password' ].includes(c.method))).toEqual([]);
    // What the page sent validate stood in for the password: it never saw it.
    expect(JSON.stringify(calls.filter((c) => c.method === 'validate'))).not.toContain(PASSWORD);

    await h.openSettings(page);
    await h.showTab(page, 'https');
    await expect(field(page, 'auth_password')).toHaveValue('');
    await expect(field(page, 'auth_password')).toHaveAttribute('placeholder', 'Unchanged');
    expect(await page.content()).not.toContain(hash);
    await h.screenshot(page, 'settings-auth-saved');
  });

  test('keeps the saved hash while the password field is empty', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await expect(field(page, 'auth_user')).toHaveValue('prom');
    await expect(field(page, 'auth_password')).toHaveValue('');
    await field(page, 'listen_port').fill('9101');
    await saveAndApply(page);
    await applied(page);

    const main = await savedMain(request);
    expect([ main.listen_port, main.auth_user, await savedHash(request) ]).toEqual([ '9101', 'prom', SAVED_HASH ]);
    expect(calls.filter((c) => c.method === 'stage_password')).toEqual([]);
    // validate was given no hash: it checked the saved one, which the page never had.
    expect(JSON.stringify(calls.filter((c) => c.method === 'validate'))).not.toContain(SAVED_HASH);
  });

  // As every other setting: Save stages it, and Save & Apply applies it.
  test('Save stages a new password, and Save & Apply applies it', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'auth_password').fill(PASSWORD);
    await page.locator('#view .cbi-page-actions').getByText('Save', { exact: true }).click();
    await expect(field(page, 'auth_password')).toHaveAttribute('placeholder', 'Applied on Save & Apply');
    await expect(field(page, 'auth_password')).toHaveValue('');
    expect(await savedHash(request)).toBe(SAVED_HASH);

    // A Save of another setting does not take it for a user without a password.
    await field(page, 'listen_port').fill('9101');
    await page.locator('#view .cbi-page-actions').getByText('Save', { exact: true }).click();
    await expect(h.saveError(page)).toBeHidden();
    expect(await savedHash(request)).toBe(SAVED_HASH);

    await saveAndApply(page);
    await applied(page);
    const hash = await savedHash(request);
    expect(hash).toMatch(/^\$6\$rounds=1000\$/);
    expect(hash).not.toBe(SAVED_HASH);
    expect((await savedMain(request)).listen_port).toBe('9101');
  });

  test('a new password replaces the saved hash', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'auth_password').fill(PASSWORD);
    await saveAndApply(page);
    await applied(page);

    const hash = await savedHash(request);
    expect(hash).toMatch(/^\$6\$rounds=1000\$/);
    expect(hash).not.toBe(SAVED_HASH);
  });

  test('emptying the user takes basic auth away, the saved hash left unused', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'auth_user').fill('');
    await saveAndApply(page);
    await applied(page);

    const main = await savedMain(request);
    expect([ main.auth_user, main.auth_password, main.cert, await savedHash(request) ]).toEqual([ undefined, undefined, '/etc/uhttpd.crt', SAVED_HASH ]);
  });

  test('refuses a user without a password', async ({ page, request }) => {
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'cert').fill('/etc/uhttpd.crt');
    await field(page, 'key').fill('/etc/uhttpd.key');
    await field(page, 'auth_user').fill('prom');
    await saveAndApply(page);
    await refused(page, [
      'HTTPS & login → Basic auth password: Basic auth password must be set along with Basic auth user',
    ]);
    await expect(field(page, 'auth_password')).toHaveClass(/cbi-input-invalid/);
    expect(await h.readConfig(request)).toBe(before);
  });

  // A saved hash of a round more than the exporter computes (2000), as test/fixtures/luci/auth/auth-rounds has it.
  test('refuses a saved hash of more rounds than basic auth takes, saying why but not the hash', async ({ page, request }) => {
    await h.useConfig(request, 'auth-rounds');
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await field(page, 'listen_port').fill('9101');
    await saveAndApply(page);
    await refused(page, [
      'HTTPS & login → Basic auth password: Basic auth password must be a hash of at most 2000 rounds, which a scrape computes to check the password',
    ]);
    expect(await h.readConfig(request)).toBe(before);
    expect(await page.content()).not.toContain('nNEbd373Z0DGjjhqlxU');

    // A new password replaces it with hash_password's, which it takes.
    await h.showTab(page, 'https');
    await field(page, 'auth_password').fill(PASSWORD);
    await saveAndApply(page);
    await applied(page);
    expect(await savedHash(request)).toMatch(/^\$6\$rounds=1000\$/);
  });

  test('refuses a user basic auth cannot send, with a ":"', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'auth_user').fill('pr:om');
    await saveAndApply(page);
    await refused(page, [ 'HTTPS & login → Basic auth user: Basic auth user must be 1 to 64 characters, without ":", spaces or control characters, not "pr:om"' ]);
    expect((await savedMain(request)).auth_user).toBe('prom');
  });

  test('writes compress 0 when it is switched off, and 1 when on', async ({ page, request }) => {
    await h.openSettings(page);
    await flag(page, 'compress').uncheck();
    await saveAndApply(page);
    await applied(page);
    expect((await savedMain(request)).compress).toBe('0');

    await h.openSettings(page);
    await expect(flag(page, 'compress')).not.toBeChecked();
    await flag(page, 'compress').check();
    await saveAndApply(page);
    await applied(page);
    expect((await savedMain(request)).compress).toBe('1');
  });
});

test.describe('The hash, over rpcd', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('a login with the app\'s ACL stages a password in its session, which its apply commits, and reads whether one is saved, never the hash', async ({ request }) => {
    const sid = await h.sessionOf(request, h.APP_USER);
    expect(await h.ubus(request, h.CONFIG, 'password', {}, h.APP_USER)).toEqual({ saved: false });
    expect(await h.ubus(request, h.CONFIG, 'stage_password', { password: PASSWORD }, h.APP_USER)).toEqual({ staged: true });
    // Staged: not saved, and in no change the session may list.
    expect([ await savedHash(request), await h.ubus(request, h.CONFIG, 'password', {}, h.APP_USER) ]).toEqual([ undefined, { saved: false } ]);
    expect(JSON.stringify(await h.ubus(request, 'uci', 'changes', {}, h.APP_USER))).not.toContain('auth_password');
    await h.ubus(request, 'uci', 'apply', { rollback: false }, h.APP_USER);
    expect(await savedHash(request)).toMatch(/^\$6\$rounds=1000\$/);
    expect(await h.ubus(request, h.CONFIG, 'password', {}, h.APP_USER)).toEqual({ saved: true });
    expect(await h.ubus(request, h.CONFIG, 'stage_password', { password: '' }, h.APP_USER)).toEqual({ staged: false });
    await h.ubus(request, 'uci', 'apply', { rollback: false }, h.APP_USER);
    expect(await savedHash(request)).toBeUndefined();
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'set_password', { password: PASSWORD }))).toBe(true);
  });

  test('a password staged and rolled back leaves the saved hash', async ({ request }) => {
    await h.useConfig(request, 'auth');
    expect(await h.ubus(request, h.CONFIG, 'stage_password', { password: PASSWORD }, h.APP_USER)).toEqual({ staged: true });
    await h.ubus(request, 'uci', 'apply', { rollback: true, timeout: 5 }, h.APP_USER);
    expect(await savedHash(request)).not.toBe(SAVED_HASH);
    await expect.poll(() => savedHash(request), { timeout: 20000 }).toBe(SAVED_HASH);
  });

  test('a login with the app\'s ACL cannot read the hash\'s config, nor hash_password', async ({ request }) => {
    await h.useConfig(request, 'auth');
    const sid = await h.sessionOf(request, h.APP_USER);
    const read = await h.rawCall(request, sid, 'uci', 'get', { config: 'prometheus-exporter-auth' });
    expect(h.denied(read), JSON.stringify(read)).toBe(true);
    expect(JSON.stringify(read)).not.toContain(SAVED_HASH);
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'hash_password', { password: PASSWORD }))).toBe(true);
    // The exporter's own config it reads, without the hash.
    const own = await h.ubus(request, 'uci', 'get', { config: h.CONFIG }, h.APP_USER);
    expect(JSON.stringify(own)).not.toContain(SAVED_HASH);
  });

  test('a login that may only read cannot save a password', async ({ request }) => {
    const sid = await h.sessionOf(request, h.VIEWER);
    expect(await h.ubus(request, h.CONFIG, 'password', {}, h.VIEWER)).toEqual({ saved: false });
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'set_password', { password: PASSWORD }))).toBe(true);
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'stage_password', { password: PASSWORD }))).toBe(true);
    expect(await savedHash(request)).toBeUndefined();
  });

  test('stage_password refuses a password it does not take, without saying it', async ({ request }) => {
    const res = await h.ubus(request, h.CONFIG, 'stage_password', { password: 'a\tb' }, h.APP_USER);
    expect(res).toEqual({ error: 'ARGS_INVALID', message: 'password: expected a password without control characters' });
  });

  test('hash_password and set_password are in no ACL of LuCI\'s: rpcd refuses them over HTTP, even to root', async ({ request }) => {
    const sid = await h.sessionOf(request, { username: 'root', password: 'admin' });
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'hash_password', { password: PASSWORD }))).toBe(true);
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'set_password', { password: PASSWORD }))).toBe(true);
  });
});
