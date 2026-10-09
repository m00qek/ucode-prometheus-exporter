const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Basic auth, on the HTTPS & login tab of Services → Prometheus exporter, and compress,
// on its General tab. The password is no field of the form: its row says whether a hash
// is saved, and its Change password dialog, typed twice, and Remove password hand it to
// the ubus object's set_password, which saves or removes its hash in
// prometheus-exporter-auth, which the page never reads, at once, apart from Save, Save &
// Apply and Revert. Basic auth takes the TLS certificate and key.

// `uhttpd -m secret`, as test/fixtures/luci/auth/auth has it.
const SAVED_HASH = '$1$$ysVNzQc4CTMkp5daOdZ.3/';
const PASSWORD = 'browser-secret';

function field(page, option) {
  return page.locator(`[id="widget.cbid.${h.CONFIG}.main.${option}"]`);
}

function flag(page, option) {
  return page.locator(`[id="cbid.${h.CONFIG}.main.${option}"] input[type="checkbox"]`);
}

// The password's row, and its buttons: Change password is the option's widget.
function passwordRow(page) {
  return page.locator('#view .cbi-value[data-name="auth_password"]');
}

function changeButton(page) {
  return field(page, 'auth_password');
}

function removeButton(page) {
  return passwordRow(page).getByRole('button', { name: 'Remove password', exact: true });
}

function passwordState(page) {
  return passwordRow(page).locator('.exporter-password-state');
}

// The dialog of a new password, and that of the hash's removal.
function changeDialog(page) {
  return h.modal(page).filter({ has: page.locator('h4', { hasText: /^Change the basic auth password$/ }) });
}

function removeDialog(page) {
  return h.modal(page).filter({ has: page.locator('h4', { hasText: /^Remove the basic auth password$/ }) });
}

// Changes the password through its dialog, `confirm` typed as the confirmation.
async function changePassword(page, password, confirm) {
  await changeButton(page).click();
  const dialog = changeDialog(page);
  await expect(dialog).toBeVisible();
  await expect(dialog.locator('[id="widget.exporter-password-new"]')).toBeFocused();
  await dialog.locator('[id="widget.exporter-password-new"]').fill(password);
  await dialog.locator('[id="widget.exporter-password-confirm"]').fill(confirm ?? password);
  await dialog.getByRole('button', { name: 'Change password', exact: true }).click();
  return dialog;
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

  test('has a user field, the password\'s row, which takes TLS, and compress on by default', async ({ page }) => {
    await h.openSettings(page);
    await expect(flag(page, 'compress')).toBeChecked();
    await h.showTab(page, 'https');
    await expect(field(page, 'auth_user')).toBeVisible();
    await expect(field(page, 'auth_user')).toHaveValue('');
    await expect(field(page, 'auth_user')).toHaveAttribute('placeholder', 'None');
    // What basic auth takes is said before a Save is refused for it, once: by the tab.
    await expect(page.locator('#view div[data-tab="https"] .cbi-tab-descr')).toHaveText('Basic auth needs HTTPS: set the certificate and key first.');
    await expect(page.locator('[data-name="auth_user"] .cbi-value-description')).toHaveText('With a password, a scrape logs in as this user. Empty for none.');
    await expect(passwordRow(page)).toContainText('Saved as a hash; the password itself is never stored. Changing or removing it applies at once, apart from Save & Apply.');
    // No field: nothing of it is the form's.
    await expect(passwordRow(page).locator('input:not([type="hidden"])')).toHaveCount(0);
    await expect(passwordState(page)).toHaveText('Not set');
    await expect(removeButton(page)).toBeHidden();
    await expect(changeButton(page)).toBeDisabled();
    await expect(passwordRow(page)).toContainText('Set TLS certificate and TLS key first: basic auth needs HTTPS.');

    await field(page, 'cert').fill('/etc/uhttpd.crt');
    await expect(changeButton(page)).toBeDisabled();
    await field(page, 'key').fill('/etc/uhttpd.key');
    await expect(changeButton(page)).toBeEnabled();
    await expect(passwordRow(page)).not.toContainText('Set TLS certificate');
    await h.screenshot(page, 'settings-auth-empty');
  });

  test('refuses basic auth without the TLS certificate and key, and saves nothing', async ({ page, request }) => {
    const before = await h.readConfig(request);
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'auth_user').fill('prom');
    await expect(field(page, 'auth_user')).toHaveClass(/cbi-input-invalid/);
    await saveAndApply(page);
    await refused(page, [
      'HTTPS & login → Basic auth password: Basic auth password must be set along with Basic auth user',
      'HTTPS & login → Basic auth user: Basic auth user needs HTTPS: set TLS certificate and TLS key, or the password crosses the network in the clear',
    ]);
    expect(await h.readConfig(request)).toBe(before);
    expect(calls.filter((c) => c.method === 'set_password')).toEqual([]);
    expect(await savedHash(request)).toBeUndefined();
  });

  test('Change password has the ubus object save the hash at once, never the password, and the page never reads the hash', async ({ page, request }) => {
    const before = await h.readConfig(request);
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await field(page, 'cert').fill('/etc/uhttpd.crt');
    await field(page, 'key').fill('/etc/uhttpd.key');
    await field(page, 'auth_user').fill('prom');
    await changePassword(page, PASSWORD);
    await expect(changeDialog(page)).toBeHidden();
    await expect(page.getByText('The basic auth password was changed, and the exporter reloads with it. Give every scraper the new one.')).toBeVisible();
    await expect(passwordState(page)).toHaveText('Set');
    await expect(changeButton(page)).toBeFocused();

    // Saved at once, alone: the form's fields are not, and nothing is staged.
    const hash = await savedHash(request);
    expect(hash).toMatch(/^\$6\$rounds=1000\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$/);
    expect(await h.readConfig(request)).toBe(before);
    expect(await h.staged(page)).toEqual({});
    expect(calls.filter((c) => c.method === 'set_password')).toEqual([ { method: 'set_password', params: { password: PASSWORD } } ]);

    // The user it waited for is saved with the rest.
    await saveAndApply(page);
    await applied(page);
    const main = await savedMain(request);
    expect([ main.auth_user, main.auth_password, await savedHash(request) ]).toEqual([ 'prom', undefined, hash ]);
    expect(await h.readConfig(request)).not.toContain(PASSWORD);
    expect(await h.readAuth(request)).not.toContain(PASSWORD);
    expect(calls.filter((c) => c.method === 'hash_password')).toEqual([]);
    expect(calls.filter((c) => c.method === 'set_password')).toHaveLength(1);
    // validate was given no password, nor a hash: it checked the saved one.
    expect(JSON.stringify(calls.filter((c) => c.method === 'validate'))).not.toContain(PASSWORD);
    expect(JSON.stringify(calls.filter((c) => c.method === 'validate'))).not.toContain('auth_password');

    await h.openSettings(page);
    await h.showTab(page, 'https');
    await expect(passwordState(page)).toHaveText('Set');
    expect(await page.content()).not.toContain(hash);
    await h.screenshot(page, 'settings-auth-saved');
  });

  test('a changed password is in no Save, Save & Apply or Revert: Revert leaves it', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await h.showTab(page, 'https');
    await expect(passwordState(page)).toHaveText('Set');
    await changePassword(page, PASSWORD);
    await expect(changeDialog(page)).toBeHidden();
    const hash = await savedHash(request);
    expect(hash).toMatch(/^\$6\$rounds=1000\$/);
    expect(hash).not.toBe(SAVED_HASH);
    expect(await h.staged(page)).toEqual({});

    // Save stages the exporter's config alone, nothing of the password; Revert drops it,
    // and leaves the password.
    await field(page, 'listen_port').fill('9101');
    await page.locator('#view .cbi-page-actions').getByText('Save', { exact: true }).click();
    await expect(h.saveError(page)).toBeHidden();
    await expect.poll(async () => Object.keys(await h.staged(page))).toEqual([ h.CONFIG ]);
    const staged = await h.staged(page);
    expect(staged[h.CONFIG]).toContainEqual([ 'set', 'main', 'listen_port', '9101' ]);
    expect(JSON.stringify(staged)).not.toContain('auth_password');
    await page.evaluate(async () => (await L.require('ui')).changes.revert());
    await page.locator('#view').waitFor();
    await expect.poll(() => h.staged(page)).toEqual({});
    expect([ await h.readConfig(request), await savedHash(request) ]).toEqual([ before, hash ]);
  });

  test('Change password takes the same password twice, and one the object hashes, before it calls', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await h.showTab(page, 'https');

    const dialog = await changePassword(page, PASSWORD, 'something-else');
    await expect(dialog.locator('.alert-message.error')).toHaveText('The passwords do not match');
    await expect(dialog.locator('[id="widget.exporter-password-confirm"]')).toHaveClass(/cbi-input-invalid/);
    await h.screenshot(page, 'settings-auth-change');

    await dialog.locator('[id="widget.exporter-password-new"]').fill('a\tb');
    await dialog.locator('[id="widget.exporter-password-confirm"]').fill('a\tb');
    await dialog.getByRole('button', { name: 'Change password', exact: true }).click();
    await expect(dialog.locator('.alert-message.error')).toHaveText('No control characters');

    await dialog.locator('[id="widget.exporter-password-new"]').fill('');
    await dialog.locator('[id="widget.exporter-password-confirm"]').fill('');
    await dialog.getByRole('button', { name: 'Change password', exact: true }).click();
    await expect(dialog.locator('.alert-message.error')).toHaveText('Expecting a password');

    // Cancel changes nothing, and gives the focus back.
    await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(h.modal(page)).toBeHidden();
    await expect(changeButton(page)).toBeFocused();

    // Escape is Cancel.
    await changeButton(page).click();
    await expect(changeDialog(page)).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(h.modal(page)).toBeHidden();
    expect(calls.filter((c) => c.method === 'set_password')).toEqual([]);
    expect(await savedHash(request)).toBe(SAVED_HASH);
  });

  test('a password the object could not save says why, in the dialog', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await page.route(/\/ubus\//, async (route) => {
      const body = JSON.parse(route.request().postData() ?? 'null');
      const calls = [].concat(body ?? []);
      const ours = (c) => c?.method === 'call' && c.params?.[1] === h.CONFIG && c.params?.[2] === 'set_password';
      if (!calls.some(ours))
        return route.continue();
      const out = calls.map((c) => ({ jsonrpc: '2.0', id: c.id, result: [ 0, {
        error: 'FILE_UNWRITABLE', message: 'FILE_UNWRITABLE (cannot write /etc/config/prometheus-exporter-auth: Read-only file system)' } ] }));
      await route.fulfill({ json: Array.isArray(body) ? out : out[0] });
    });
    await h.openSettings(page);
    await h.showTab(page, 'https');
    const dialog = await changePassword(page, PASSWORD);
    await expect(dialog.locator('.alert-message.error')).toHaveText(
      'The password could not be changed: FILE_UNWRITABLE (cannot write /etc/config/prometheus-exporter-auth: Read-only file system)');
    await expect(passwordState(page)).toHaveText('Set');
    expect(await savedHash(request)).toBe(SAVED_HASH);
  });

  test('Remove password removes the saved hash at once, once the user is emptied', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    const before = await h.readConfig(request);
    const calls = ubusCalls(page);
    await h.openSettings(page);
    await h.showTab(page, 'https');
    // A user needs a password: not while one is set.
    await expect(removeButton(page)).toBeVisible();
    await expect(removeButton(page)).toBeDisabled();
    await expect(passwordRow(page)).toContainText('To remove the password, empty Basic auth user and Save & Apply first: a user needs a password.');

    await field(page, 'auth_user').fill('');
    await expect(removeButton(page)).toBeEnabled();
    await removeButton(page).click();
    const dialog = removeDialog(page);
    await expect(dialog).toContainText('The saved password is removed at once, apart from Save & Apply and Revert.');
    await expect(dialog.getByRole('button', { name: 'Cancel', exact: true })).toBeFocused();
    await dialog.getByRole('button', { name: 'Remove password', exact: true }).click();
    await expect(h.modal(page)).toBeHidden();
    await expect(page.getByText('The basic auth password was removed.')).toBeVisible();
    await expect(passwordState(page)).toHaveText('Not set');
    await expect(removeButton(page)).toBeHidden();
    expect([ await savedHash(request), await h.readConfig(request) ]).toEqual([ undefined, before ]);
    expect(calls.filter((c) => c.method === 'set_password')).toEqual([ { method: 'set_password', params: { password: '' } } ]);

    // Basic auth is off once the emptied user is applied.
    await saveAndApply(page);
    await applied(page);
    expect((await savedMain(request)).auth_user).toBeUndefined();
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

  test('refuses a user without a password, until one is changed', async ({ page, request }) => {
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
    await expect(changeButton(page)).toHaveClass(/cbi-input-invalid/);
    await expect(passwordRow(page).locator('.exporter-password-refusal')).toHaveText('Basic auth password must be set along with Basic auth user');
    expect(await h.readConfig(request)).toBe(before);

    // The refusal's link shows the row's Change password.
    await h.showTab(page, 'general');
    await page.locator('#view .alert-message.error .exporter-line a').click();
    await expect(changeButton(page)).toBeFocused();

    await changePassword(page, PASSWORD);
    await expect(changeButton(page)).not.toHaveClass(/cbi-input-invalid/);
    await saveAndApply(page);
    await applied(page);
    expect((await savedMain(request)).auth_user).toBe('prom');
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

    // A new password replaces it with set_password's, which it takes.
    await h.showTab(page, 'https');
    await changePassword(page, PASSWORD);
    await expect(changeDialog(page)).toBeHidden();
    expect(await savedHash(request)).toMatch(/^\$6\$rounds=1000\$/);
    await saveAndApply(page);
    await applied(page);
    expect((await savedMain(request)).listen_port).toBe('9101');
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

test.describe('Services → Prometheus exporter: basic auth, for a login that may only read', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('says whether a password is saved, and can neither change nor remove it', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openSettings(page, h.VIEWER);
    await h.showTab(page, 'https');
    await expect(passwordState(page)).toHaveText('Set');
    await expect(changeButton(page)).toBeDisabled();
    await expect(removeButton(page)).toBeDisabled();
    await expect(passwordRow(page)).not.toContainText('Set TLS certificate');
    expect(await savedHash(request)).toBe(SAVED_HASH);
  });
});

test.describe('The hash, over rpcd', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('a login with the app\'s ACL saves and removes a password by set_password, and reads whether one is saved, never the hash', async ({ request }) => {
    expect(await h.ubus(request, h.CONFIG, 'password', {}, h.APP_USER)).toEqual({ saved: false });
    expect(await h.ubus(request, h.CONFIG, 'set_password', { password: PASSWORD }, h.APP_USER)).toEqual({ saved: true });
    expect(await h.ubus(request, h.CONFIG, 'password', {}, h.APP_USER)).toEqual({ saved: true });
    expect(await savedHash(request)).toMatch(/^\$6\$rounds=1000\$/);
    expect(await h.ubus(request, h.CONFIG, 'set_password', { password: '' }, h.APP_USER)).toEqual({ saved: false });
    expect(await savedHash(request)).toBeUndefined();
  });

  test('a login with the app\'s ACL can neither read nor write the hash\'s config, nor call hash_password', async ({ request }) => {
    await h.useConfig(request, 'auth');
    const sid = await h.sessionOf(request, h.APP_USER);
    const read = await h.rawCall(request, sid, 'uci', 'get', { config: 'prometheus-exporter-auth' });
    expect(h.denied(read), JSON.stringify(read)).toBe(true);
    expect(JSON.stringify(read)).not.toContain(SAVED_HASH);
    const write = await h.rawCall(request, sid, 'uci', 'set', { config: 'prometheus-exporter-auth', section: 'main', values: { auth_password: '$1$$x' } });
    expect(h.denied(write), JSON.stringify(write)).toBe(true);
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'hash_password', { password: PASSWORD }))).toBe(true);
    // The exporter's own config it reads, without the hash.
    const own = await h.ubus(request, 'uci', 'get', { config: h.CONFIG }, h.APP_USER);
    expect(JSON.stringify(own)).not.toContain(SAVED_HASH);
    expect(await savedHash(request)).toBe(SAVED_HASH);
  });

  test('a login that may only read can neither save nor remove a password', async ({ request }) => {
    await h.useConfig(request, 'auth');
    const sid = await h.sessionOf(request, h.VIEWER);
    expect(await h.ubus(request, h.CONFIG, 'password', {}, h.VIEWER)).toEqual({ saved: true });
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'set_password', { password: PASSWORD }))).toBe(true);
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'set_password', { password: '' }))).toBe(true);
    expect(await savedHash(request)).toBe(SAVED_HASH);
  });

  test('set_password refuses a password it does not take, without saying it', async ({ request }) => {
    const res = await h.ubus(request, h.CONFIG, 'set_password', { password: 'a\tb' }, h.APP_USER);
    expect(res).toEqual({ error: 'ARGS_INVALID', message: 'password: expected a password without control characters' });
    expect(await savedHash(request)).toBeUndefined();
  });

  test('hash_password is in no ACL of LuCI\'s: rpcd refuses it over HTTP, even to root', async ({ request }) => {
    const sid = await h.sessionOf(request, { username: 'root', password: 'admin' });
    expect(h.denied(await h.rawCall(request, sid, h.CONFIG, 'hash_password', { password: PASSWORD }))).toBe(true);
  });
});
