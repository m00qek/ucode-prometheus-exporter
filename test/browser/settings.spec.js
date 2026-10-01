const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Services → Prometheus exporter against the real rpcd plugin and the exporter's real
// collectors, with the configuration the tests lay out (test/fixtures/luci/config/).

function field(page, option) {
  return page.locator(`[id="widget.cbid.${h.CONFIG}.main.${option}"]`);
}

function flag(page, option) {
  return page.locator(`[id="cbid.${h.CONFIG}.main.${option}"] input[type="checkbox"]`);
}

function listen(page) {
  return page.locator(`[id="cbid.${h.CONFIG}.main.listen_interface"]`);
}

function option(page, id, name) {
  return page.locator(`[id="widget.cbid.${h.CONFIG}.${id}.${name}"]`);
}

function toggle(page, id, name) {
  return page.locator(`[id="cbid.${h.CONFIG}.${id}.${name ?? 'enabled'}"] input[type="checkbox"]`);
}

function panel(page) {
  return page.locator('#view > div > div.alert-message, #view .alert-message.error');
}

async function saveAndApply(page) {
  await page.locator('#view .cbi-page-actions').getByText('Save & Apply', { exact: true }).click();
}

// LuCI confirms an apply from the page that made it; one left unconfirmed would be
// confirmed by the next page loaded, in the next test.
async function applied(page) {
  await expect(page.getByText('Configuration changes applied.')).toBeVisible({ timeout: 30000 });
}

async function savedSections(request) {
  return h.sections(await h.readConfig(request));
}

test.describe('Services → Prometheus exporter', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('shows the exporter settings as saved', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.openSettings(page);
    await expect(flag(page, 'enabled')).toBeChecked();
    await expect(listen(page).locator('li[selected]')).toHaveAttribute('data-value', '*');
    await expect(field(page, 'listen_port')).toHaveValue('9102');
    await expect(field(page, 'http_keepalive')).toHaveValue('0');
    await expect(field(page, 'cert')).toHaveValue('');
    await expect(field(page, 'cert')).toHaveAttribute('placeholder', '/etc/uhttpd.crt');
    await expect(flag(page, 'omit_zero_values')).toBeChecked();
    await expect(page.locator('#view .cbi-map-descr a')).toHaveAttribute('href', `/cgi-bin/luci/admin/status/${h.CONFIG}`);
    await h.screenshot(page, 'settings-custom');
  });

  test('offers every address and the router\'s networks to listen on', async ({ page }) => {
    await h.openSettings(page);
    await expect(listen(page).locator('li[selected]')).toHaveAttribute('data-value', 'loopback');
    const values = await listen(page).locator('li[data-value]').evaluateAll((items) => items.map((li) => li.getAttribute('data-value')));
    expect(values.sort()).toEqual([ '*', 'lan', 'loopback', 'wan' ]);
  });

  test('has a row for each installed collector, saying where it comes from and what it reads', async ({ page, request }) => {
    const plugin = await h.ubus(request, h.CONFIG, 'collectors', {});
    await h.openSettings(page);

    const rows = await page.locator('#view tr[data-collector]').evaluateAll((trs) => trs.map((tr) => tr.getAttribute('data-collector')));
    expect(rows).toEqual(plugin.collectors.map((c) => c.id));
    expect(rows).toEqual(expect.arrayContaining([ 'loadavg', 'wifi', 'textfile', 'dhcp_leases', 'wireguard', 'ltq_dsl', 'sampler' ]));

    await expect(h.collectorRow(page, 'loadavg').locator('td').first()).toContainText('In the base package');
    await expect(h.collectorRow(page, 'wifi').locator('td').first())
      .toContainText(`Package ${h.CONFIG}-wifi, which can be removed`);
    await expect(h.collectorRow(page, 'sampler').locator('td').first()).toContainText('Not installed by a package');
    await expect(h.collectorRow(page, 'wireguard').locator('td').first()).toContainText('Reads /etc/config/network');
    await expect(h.collectorRow(page, 'dhcp_leases').locator('td').first()).toContainText('Reads /etc/config/dhcp');
    await expect(h.collectorRow(page, 'ltq_dsl').locator('td').first()).toContainText('ltq-dsl');
    await expect(h.collectorRow(page, 'loadavg').locator('td').first()).toContainText('Load averages');
    await h.screenshot(page, 'settings-collectors');
  });

  test('renders each option by its type, with its default', async ({ page }) => {
    await h.openSettings(page);
    await expect(toggle(page, 'wifi', 'stations')).toBeChecked();
    await expect(toggle(page, 'dhcp_leases', 'leases')).not.toBeChecked();
    await expect(toggle(page, 'sampler', 'verbose')).not.toBeChecked();
    await expect(option(page, 'textfile', 'directory')).toHaveValue('');
    await expect(option(page, 'textfile', 'directory')).toHaveAttribute('placeholder', '/var/prometheus');
    await expect(option(page, 'sampler', 'retries')).toHaveAttribute('placeholder', '3');
    await expect(option(page, 'sampler', 'label')).toHaveAttribute('placeholder', 'node');
    await expect(h.collectorRow(page, 'loadavg').locator('td').last()).toHaveText('None');
    for (const id of [ 'loadavg', 'wifi', 'sampler' ])
      await expect(toggle(page, id)).toBeChecked();
  });

  test('shows the saved collector sections', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.openSettings(page);
    await expect(toggle(page, 'wifi', 'stations')).not.toBeChecked();
    await expect(toggle(page, 'textfile')).not.toBeChecked();
    await expect(option(page, 'textfile', 'directory')).toHaveValue('/srv/prom');
    await expect(toggle(page, 'wifi')).toBeChecked();
  });

  test('switching a collector off saves only that, and switching it on again removes its section', async ({ page, request }) => {
    await h.openSettings(page);
    await toggle(page, 'loadavg').uncheck();
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).loadavg).toEqual({ '.type': 'collector', enabled: '0' });

    await h.openSettings(page);
    await expect(toggle(page, 'loadavg')).not.toBeChecked();
    await toggle(page, 'loadavg').check();
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).loadavg).toBeUndefined();
  });

  test('an option off its default gets a section of its own, which goes once it is back', async ({ page, request }) => {
    await h.openSettings(page);
    await option(page, 'sampler', 'retries').fill('5');
    await toggle(page, 'sampler', 'verbose').check();
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).sampler).toEqual({ '.type': 'collector', retries: '5', verbose: '1' });

    await h.openSettings(page);
    await expect(option(page, 'sampler', 'retries')).toHaveValue('5');
    await option(page, 'sampler', 'retries').fill('3');
    await toggle(page, 'sampler', 'verbose').uncheck();
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).sampler).toBeUndefined();
  });

  test('changes only the collectors whose rows changed', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.openSettings(page);
    await option(page, 'textfile', 'directory').fill('');
    await saveAndApply(page);
    await applied(page);
    const saved = await savedSections(request);
    expect(saved.textfile).toEqual({ '.type': 'collector', enabled: '0' });
    expect(saved.wifi).toEqual({ '.type': 'collector', stations: '0' });
    expect(saved.main).toEqual({ '.type': h.CONFIG, listen_interface: '*', listen_port: '9102', http_keepalive: '0', omit_zero_values: '1' });
  });

  test('refuses what an option\'s datatype refuses, and saves nothing', async ({ page, request }) => {
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await option(page, 'sampler', 'retries').fill('many');
    await expect(option(page, 'sampler', 'retries')).toHaveClass(/cbi-input-invalid/);
    await expect(option(page, 'sampler', 'retries')).toHaveAttribute('data-tooltip', 'Expecting: valid integer value');
    await saveAndApply(page);
    // The plugin refuses it as well, so nothing reaches the form's own save.
    await expect(page.locator('#view .alert-message.error li')).toHaveText([ 'sampler retries: expected an integer, got "many"' ]);
    expect(await h.readConfig(request)).toBe(before);
  });

  test('marks what the exporter would refuse, as the plugin says, and saves nothing', async ({ page, request }) => {
    const before = await h.readConfig(request);
    await h.openSettings(page);
    // LuCI's port datatype takes 0; the exporter does not.
    await field(page, 'listen_port').fill('0');
    await expect(field(page, 'listen_port')).toHaveClass(/cbi-input-invalid/);
    await expect(field(page, 'listen_port')).toHaveAttribute('data-tooltip', 'expected an integer from 1 to 65535, got 0');
    await saveAndApply(page);
    await expect(page.locator('#view .alert-message.error')).toContainText('Nothing was saved: the exporter would refuse these values.');
    await expect(page.locator('#view .alert-message.error li')).toHaveText([ 'Port: expected an integer from 1 to 65535, got 0' ]);
    expect(await h.readConfig(request)).toBe(before);
    await h.screenshot(page, 'settings-refused');

    await field(page, 'listen_port').fill('9105');
    await expect(field(page, 'listen_port')).not.toHaveClass(/cbi-input-invalid/);
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).main.listen_port).toBe('9105');
  });

  test('says a saved collector section is not valid, as the exporter reads it', async ({ page, request }) => {
    await h.useConfig(request, 'invalid');
    await h.openSettings(page);
    await expect(h.collectorRow(page, 'sampler').locator('td').first())
      .toContainText('The saved settings are not valid: CONFIG_INVALID (retries: expected an integer, got "many")');
    await expect(option(page, 'sampler', 'retries')).toHaveValue('many');
    await expect(option(page, 'sampler', 'retries')).toHaveClass(/cbi-input-invalid/);
  });
});

test.describe('Services → Prometheus exporter, for a login with the app\'s ACL alone', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('shows and saves the settings, without reading the network configuration', async ({ page, request }) => {
    await h.openSettings(page, h.APP_USER);
    // The picker cannot list the networks: it keeps the saved one, and every address.
    const values = await listen(page).locator('li[data-value]').evaluateAll((items) => items.map((li) => li.getAttribute('data-value')));
    expect(values.sort()).toEqual([ '*', 'loopback' ]);
    await expect(page.locator('#view tr[data-collector="loadavg"]')).toBeVisible();

    await field(page, 'listen_port').fill('9103');
    await toggle(page, 'wifi', 'stations').uncheck();
    await saveAndApply(page);
    await applied(page);
    const saved = await savedSections(request);
    expect(saved.main.listen_port).toBe('9103');
    expect(saved.wifi).toEqual({ '.type': 'collector', stations: '0' });

    const sid = await h.sessionOf(request, h.APP_USER);
    expect(h.denied(await h.rawCall(request, sid, 'uci', 'get', { config: 'network' }))).toBe(true);
  });
});
