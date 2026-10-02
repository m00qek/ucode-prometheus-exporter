const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Basic auth and compress on the Exporter tab of Services → Prometheus exporter. The
// password is typed, hashed on Save by the ubus object's hash_password, and only the
// hash is saved; basic auth takes the TLS certificate and key.

// `uhttpd -m secret`, as test/fixtures/luci/config/auth has it.
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
    await expect(field(page, 'auth_user')).toHaveValue('');
    await expect(field(page, 'auth_user')).toHaveAttribute('placeholder', 'None');
    // What basic auth takes is said before a Save is refused for it.
    await expect(page.locator('[data-name="auth_user"] .cbi-value-description')).toContainText('Basic auth needs HTTPS: set the TLS certificate and key first.');
    await expect(page.locator('[data-name="auth_password"] .cbi-value-description')).toHaveText('Saved as a hash; the password itself is never stored. Empty keeps the saved one.');
    await expect(field(page, 'auth_password')).toHaveValue('');
    await expect(field(page, 'auth_password')).toHaveAttribute('type', 'password');
    await expect(field(page, 'auth_password')).not.toHaveAttribute('placeholder', 'Unchanged');
    await expect(flag(page, 'compress')).toBeChecked();
    await h.screenshot(page, 'settings-auth-empty');
  });

  test('refuses basic auth without the TLS certificate and key, and saves nothing', async ({ page, request }) => {
    const before = await h.readConfig(request);
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await field(page, 'auth_user').fill('prom');
    await field(page, 'auth_password').fill(PASSWORD);
    await expect(field(page, 'auth_user')).toHaveClass(/cbi-input-invalid/);
    await saveAndApply(page);
    await refused(page, [
      'Basic auth user: basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear',
    ]);
    expect(await h.readConfig(request)).toBe(before);
    expect(calls.filter((c) => c.method === 'hash_password')).toEqual([]);
  });

  test('hashes the password through the ubus object, and saves the hash, never the password', async ({ page, request }) => {
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await field(page, 'cert').fill('/etc/uhttpd.crt');
    await field(page, 'key').fill('/etc/uhttpd.key');
    await field(page, 'auth_user').fill('prom');
    await field(page, 'auth_password').fill(PASSWORD);
    await saveAndApply(page);
    await applied(page);

    const main = await savedMain(request);
    expect(main.auth_user).toBe('prom');
    expect(main.auth_password).toMatch(/^\$6\$rounds=1000\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$/);
    expect(await h.readConfig(request)).not.toContain(PASSWORD);
    expect(calls.filter((c) => c.method === 'hash_password')).toEqual([ { method: 'hash_password', params: { password: PASSWORD } } ]);
    // What the page sent validate stood in for the password: it never saw it.
    expect(JSON.stringify(calls.filter((c) => c.method === 'validate'))).not.toContain(PASSWORD);

    await h.openSettings(page);
    await expect(field(page, 'auth_password')).toHaveValue('');
    await expect(field(page, 'auth_password')).toHaveAttribute('placeholder', 'Unchanged');
    expect(await page.content()).not.toContain(main.auth_password);
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
    expect([ main.listen_port, main.auth_user, main.auth_password ]).toEqual([ '9101', 'prom', SAVED_HASH ]);
    expect(calls.filter((c) => c.method === 'hash_password')).toEqual([]);
  });

  test('a new password replaces the saved hash', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openSettings(page);
    await field(page, 'auth_password').fill(PASSWORD);
    await saveAndApply(page);
    await applied(page);

    const main = await savedMain(request);
    expect(main.auth_password).toMatch(/^\$6\$rounds=1000\$/);
    expect(main.auth_password).not.toBe(SAVED_HASH);
  });

  test('emptying the user takes basic auth away, hash and all', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openSettings(page);
    await field(page, 'auth_user').fill('');
    await saveAndApply(page);
    await applied(page);

    const main = await savedMain(request);
    expect([ main.auth_user, main.auth_password, main.cert ]).toEqual([ undefined, undefined, '/etc/uhttpd.crt' ]);
  });

  test('refuses a user without a password', async ({ page, request }) => {
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await field(page, 'cert').fill('/etc/uhttpd.crt');
    await field(page, 'key').fill('/etc/uhttpd.key');
    await field(page, 'auth_user').fill('prom');
    await saveAndApply(page);
    await refused(page, [
      'Basic auth password: basic auth needs the hash of a password along with auth_user',
    ]);
    await expect(field(page, 'auth_password')).toHaveClass(/cbi-input-invalid/);
    expect(await h.readConfig(request)).toBe(before);
  });

  // A saved hash of a round more than the exporter computes (2000), as test/fixtures/luci/config/auth-rounds has it.
  test('refuses a saved hash of more rounds than basic auth takes, saying why but not the hash', async ({ page, request }) => {
    await h.useConfig(request, 'auth-rounds');
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await field(page, 'listen_port').fill('9101');
    await saveAndApply(page);
    await refused(page, [
      /^Basic auth password: expected a hash of at most 2000 rounds, which a scrape computes to check the password/,
    ]);
    expect(await h.readConfig(request)).toBe(before);
    expect(await page.content()).not.toContain('nNEbd373Z0DGjjhqlxU');

    // A new password replaces it with hash_password's, which it takes.
    await field(page, 'auth_password').fill(PASSWORD);
    await saveAndApply(page);
    await applied(page);
    expect((await savedMain(request)).auth_password).toMatch(/^\$6\$rounds=1000\$/);
  });

  test('refuses a user basic auth cannot send, with a ":"', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openSettings(page);
    await field(page, 'auth_user').fill('pr:om');
    await saveAndApply(page);
    await refused(page, [ /^Basic auth user: expected a user of 1 to 64 characters/ ]);
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

test.describe('hash_password, over rpcd', () => {
  test('is granted to a login with the app\'s ACL, and answers a hash', async ({ request }) => {
    const res = await h.ubus(request, h.CONFIG, 'hash_password', { password: PASSWORD }, h.APP_USER);
    expect(Object.keys(res)).toEqual([ 'hash' ]);
    expect(res.hash).toMatch(/^\$6\$rounds=1000\$/);
  });

  test('refuses a password it does not take, without saying it', async ({ request }) => {
    const res = await h.ubus(request, h.CONFIG, 'hash_password', { password: 'a\tb' });
    expect(res).toEqual({ error: 'ARGS_INVALID', message: 'password: expected a password without control characters' });
  });

  test('salts each hash afresh', async ({ request }) => {
    const a = await h.ubus(request, h.CONFIG, 'hash_password', { password: PASSWORD });
    const b = await h.ubus(request, h.CONFIG, 'hash_password', { password: PASSWORD });
    expect(a.hash).not.toBe(b.hash);
  });
});
