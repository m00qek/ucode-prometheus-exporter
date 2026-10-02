const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Services → Prometheus exporter against the real ubus object in rpcd and the exporter's
// real collectors, with the configuration the tests lay out (test/fixtures/luci/config/).
// The Exporter tab is the main section; the Collectors tab has a row per collector, with a
// switch, and a dialog of its options behind Edit.

function field(page, option) {
  return page.locator(`[id="widget.cbid.${h.CONFIG}.main.${option}"]`);
}

function flag(page, option) {
  return page.locator(`[id="cbid.${h.CONFIG}.main.${option}"] input[type="checkbox"]`);
}

function listen(page) {
  return page.locator(`[id="cbid.${h.CONFIG}.main.listen_interface"]`);
}

async function listenChoices(page) {
  const values = await listen(page).locator('li[data-value]').evaluateAll((items) => items.map((li) => li.getAttribute('data-value')));
  return values.sort();
}

// A field of the open dialog.
function option(page, id, name) {
  return h.modal(page).locator(`[id="widget.cbid.${h.CONFIG}.${id}.${name}"]`);
}

function checkbox(page, id, name) {
  return h.modal(page).locator(`[id="cbid.${h.CONFIG}.${id}.${name}"] input[type="checkbox"]`);
}

// A collector's switch, on its row.
function toggle(page, id) {
  return page.locator(`#view [id="cbid.${h.CONFIG}.${id}.enabled"] input[type="checkbox"]`);
}

function editButton(page, id) {
  return h.collectorRow(page, id).getByRole('button', { name: 'Edit', exact: true });
}

async function saveDialog(page) {
  await h.modal(page).getByRole('button', { name: 'Save', exact: true }).click();
  await expect(h.modal(page)).toBeHidden();
}

async function dismissDialog(page) {
  await h.modal(page).getByRole('button', { name: 'Dismiss', exact: true }).click();
  await expect(h.modal(page)).toBeHidden();
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

  test('opens on the Exporter tab, with the main section as saved', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.open(page, `admin/services/${h.CONFIG}`);
    await expect(page.locator('#view .cbi-tabmenu li[data-tab="exporter"]')).toHaveClass('cbi-tab');
    await expect(page.locator('#view .cbi-tabmenu li[data-tab="collectors"]')).toHaveClass('cbi-tab-disabled');
    const tabs = await page.locator('#view .cbi-tabmenu li[data-tab]').evaluateAll((lis) => lis.map((li) => li.getAttribute('data-tab')));
    expect(tabs).toEqual([ 'exporter', 'collectors' ]);
    await expect(page.locator('#view .cbi-tabmenu li[data-tab="exporter"]')).toHaveText('Exporter');
    await expect(page.locator('#view .cbi-tabmenu li[data-tab="collectors"]')).toHaveText('Collectors');
    await expect(flag(page, 'enabled')).toBeChecked();
    await expect(listen(page).locator('li[selected]')).toHaveAttribute('data-value', '*');
    await expect(field(page, 'listen_port')).toHaveValue('9102');
    await expect(field(page, 'http_keepalive')).toHaveValue('0');
    await expect(field(page, 'cert')).toHaveValue('');
    await expect(field(page, 'cert')).toHaveAttribute('placeholder', '/etc/uhttpd.crt');
    await expect(flag(page, 'omit_zero_values')).toBeChecked();
    await expect(field(page, 'exec_timeout')).toHaveValue('8');
    await expect(page.locator('#view .cbi-map-descr a')).toHaveAttribute('href', `/cgi-bin/luci/admin/status/${h.CONFIG}`);
    await h.screenshot(page, 'settings-custom');
  });

  test('shows every field at its value, the defaults included', async ({ page, request }) => {
    await h.useConfig(request, 'gone');
    await h.openSettings(page);
    await expect(flag(page, 'enabled')).toBeChecked();
    await expect(field(page, 'listen_port')).toHaveValue('9100');
    await expect(field(page, 'http_keepalive')).toHaveValue('70');
    await expect(flag(page, 'omit_zero_values')).not.toBeChecked();
    await expect(field(page, 'exec_timeout')).toHaveValue('5');
    await expect(field(page, 'exec_timeout')).toHaveAttribute('placeholder', '5');
    await expect(field(page, 'scrape_timeout')).toHaveValue('10');
    await expect(field(page, 'collector_budget')).toHaveValue('5');
    await expect(field(page, 'cert')).toHaveValue('');
  });

  test('writes every setting of the main section on Save & Apply, the defaults included, but no empty TLS file', async ({ page, request }) => {
    await h.useConfig(request, 'gone');
    expect((await savedSections(request)).main).toEqual({ '.type': h.CONFIG, listen_interface: 'vpn', listen_port: '9100' });
    await h.openSettings(page);
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).main).toEqual({
      '.type': h.CONFIG, enabled: '1', listen_interface: 'vpn', listen_port: '9100', http_keepalive: '70', compress: '1',
      omit_zero_values: '0', exec_timeout: '5', scrape_timeout: '10', collector_budget: '5',
    });
  });

  test('refuses to save an emptied field rather than leave the setting out', async ({ page, request }) => {
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await field(page, 'http_keepalive').fill('');
    await expect(field(page, 'http_keepalive')).toHaveClass(/cbi-input-invalid/);
    await saveAndApply(page);
    await expect(h.modal(page)).toContainText('An error occurred while saving the form');
    await expect(h.modal(page)).toContainText('Keep-alive');
    await dismissDialog(page);
    expect(await h.readConfig(request)).toBe(before);
  });

  test('offers every address and netifd\'s interfaces to listen on, as the ubus object lists them', async ({ page, request }) => {
    const reply = await h.ubus(request, h.CONFIG, 'interfaces', {});
    await h.openSettings(page);
    await expect(listen(page).locator('li[selected]')).toHaveAttribute('data-value', 'loopback');
    expect(await listenChoices(page)).toEqual([ '*', ...reply.interfaces.map((i) => i.name) ].sort());
    expect(await listenChoices(page)).toEqual([ '*', 'lan', 'loopback', 'wan' ]);
    await expect(listen(page).locator('li[data-value="wan"]')).toContainText('wan (dhcp)');
  });

  test('keeps a saved interface it does not list', async ({ page, request }) => {
    await h.useConfig(request, 'gone');
    await h.openSettings(page);
    await expect(listen(page).locator('li[selected]')).toHaveAttribute('data-value', 'vpn');
    expect(await listenChoices(page)).toEqual([ '*', 'lan', 'loopback', 'vpn', 'wan' ]);
  });

  test('has a row for each installed collector: its title and help, its package, a switch, and Edit when it has options', async ({ page, request }) => {
    const plugin = await h.ubus(request, h.CONFIG, 'collectors', {});
    await h.openSettings(page);
    await h.showTab(page, 'collectors');

    const rows = await page.locator('#view tr[data-collector]').evaluateAll((trs) => trs.map((tr) => tr.getAttribute('data-collector')));
    expect(rows).toEqual(plugin.collectors.map((c) => c.id));
    expect(rows).toEqual(expect.arrayContaining([ 'loadavg', 'wifi', 'textfile', 'dhcp_leases', 'wireguard', 'ltq_dsl', 'sampler', 'runner' ]));

    const headers = await page.locator('#view table.cbi-section-table th').allTextContents();
    expect(headers).toEqual([ 'Collector', 'Package', 'Enabled', '' ]);

    await expect(h.collectorRow(page, 'loadavg').locator('td').nth(0)).toContainText('Load average');
    await expect(h.collectorRow(page, 'loadavg').locator('td').nth(0)).toContainText('Load averages');
    await expect(h.collectorRow(page, 'loadavg').locator('td').nth(1)).toHaveText('base');
    await expect(h.collectorRow(page, 'wifi').locator('td').nth(1)).toHaveText(`${h.PACKAGE}-wifi`);
    await expect(h.collectorRow(page, 'sampler').locator('td').nth(1)).toHaveText('none');
    await expect(h.collectorRow(page, 'ltq_dsl').locator('td').first()).toContainText('ltq-dsl');

    for (const id of [ 'loadavg', 'wifi', 'sampler', 'textfile' ])
      await expect(toggle(page, id)).toBeChecked();

    const editable = await page.locator('#view tr[data-collector]').evaluateAll((trs) =>
      trs.filter((tr) => tr.querySelector('button.cbi-button-edit')).map((tr) => tr.getAttribute('data-collector')));
    expect(editable).toEqual(plugin.collectors.filter((c) => c.options.length > 0).map((c) => c.id));
    // runner declares no option, but runs a program: it has the core's timeout.
    expect(editable).toEqual(expect.arrayContaining([ 'wifi', 'textfile', 'dhcp_leases', 'wireguard', 'sampler', 'runner' ]));
    await expect(editButton(page, 'loadavg')).toHaveCount(0);
    await h.screenshot(page, 'settings-collectors');
  });

  test('shows the switches as saved', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.openSettings(page);
    await h.showTab(page, 'collectors');
    await expect(toggle(page, 'textfile')).not.toBeChecked();
    await expect(toggle(page, 'wifi')).toBeChecked();
  });

  test('switching a collector off writes its section, every option stated, and switching it on again removes it', async ({ page, request }) => {
    await h.openSettings(page);
    await h.showTab(page, 'collectors');
    await toggle(page, 'loadavg').uncheck();
    await toggle(page, 'wifi').uncheck();
    await saveAndApply(page);
    await applied(page);
    let saved = await savedSections(request);
    expect(saved.loadavg).toEqual({ '.type': 'collector', enabled: '0' });
    expect(saved.wifi).toEqual({ '.type': 'collector', enabled: '0', stations: '1' });

    await h.openSettings(page);
    await h.showTab(page, 'collectors');
    await expect(toggle(page, 'loadavg')).not.toBeChecked();
    await toggle(page, 'loadavg').check();
    await toggle(page, 'wifi').check();
    await saveAndApply(page);
    await applied(page);
    saved = await savedSections(request);
    expect(saved.loadavg).toBeUndefined();
    expect(saved.wifi).toBeUndefined();
  });

  test('Edit opens a dialog with a field per option, by its type, with its help, and what the collector reads', async ({ page }) => {
    await h.openSettings(page);
    let dialog = await h.editCollector(page, 'sampler');
    await expect(dialog.locator('h4')).toHaveText('Sampler sampler');
    await expect(dialog.locator('.exporter-editor > p').first()).toHaveText('Samples nothing, with an option of each type.');
    const fields = await dialog.locator('.cbi-value[data-option]').evaluateAll((els) => els.map((el) => el.getAttribute('data-option')));
    expect(fields).toEqual([ 'retries', 'verbose', 'label' ]);
    await expect(option(page, 'sampler', 'retries')).toHaveValue('');
    await expect(option(page, 'sampler', 'retries')).toHaveAttribute('placeholder', '3');
    await expect(option(page, 'sampler', 'label')).toHaveAttribute('placeholder', 'node');
    await expect(checkbox(page, 'sampler', 'verbose')).not.toBeChecked();
    await expect(dialog.locator('.cbi-value[data-option="retries"] .cbi-value-description')).toHaveText('How many times to try.');
    await expect(dialog.locator('.cbi-value[data-option="verbose"] .cbi-value-description')).toHaveText('Say more.');
    await expect(dialog.locator('.exporter-reads')).toContainText('Its jail mounts nothing for it but what every collector gets');
    await h.screenshot(page, 'settings-dialog');
    await dismissDialog(page);

    dialog = await h.editCollector(page, 'wifi');
    await expect(checkbox(page, 'wifi', 'stations')).toBeChecked();
    await dismissDialog(page);

    dialog = await h.editCollector(page, 'textfile');
    await expect(option(page, 'textfile', 'directory')).toHaveAttribute('placeholder', '/var/prometheus');
    await expect(dialog.locator('.exporter-reads')).toContainText('Its jail mounts, as saved: /var/prometheus.');
    await dismissDialog(page);

    dialog = await h.editCollector(page, 'dhcp_leases');
    await expect(checkbox(page, 'dhcp_leases', 'leases')).not.toBeChecked();
    await expect(dialog.locator('.exporter-reads')).toContainText('Reads /etc/config/dhcp.');
    await expect(dialog.locator('.exporter-reads')).toContainText('Its jail mounts, as saved: /etc/config/dhcp');
    await dismissDialog(page);
  });

  test('the dialog\'s Save stages its values, Save & Apply applies them, and the section goes once they are back at the defaults', async ({ page, request }) => {
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await h.editCollector(page, 'sampler');
    await option(page, 'sampler', 'retries').fill('5');
    await checkbox(page, 'sampler', 'verbose').check();
    await saveDialog(page);

    // Staged in uci for this login, as LuCI's own dialogs do, every option written out;
    // nothing written yet.
    const changes = await h.staged(page);
    expect(changes[h.CONFIG]).toEqual([
      [ 'set', 'sampler', 'collector' ], [ 'set', 'sampler', 'enabled', '1' ], [ 'set', 'sampler', 'retries', '5' ],
      [ 'set', 'sampler', 'verbose', '1' ], [ 'set', 'sampler', 'label', 'node' ],
    ]);
    expect(await h.readConfig(request)).toBe(before);
    await expect(page.locator('#indicators [data-indicator="uci-changes"]')).toContainText('Unsaved Changes');

    // The dialog opens again with what it staged.
    await h.editCollector(page, 'sampler');
    await expect(option(page, 'sampler', 'retries')).toHaveValue('5');
    await expect(checkbox(page, 'sampler', 'verbose')).toBeChecked();
    await dismissDialog(page);

    await saveAndApply(page);
    await applied(page);
    const written = { '.type': 'collector', enabled: '1', retries: '5', verbose: '1', label: 'node' };
    expect((await savedSections(request)).sampler).toEqual(written);

    await h.openSettings(page);
    await h.editCollector(page, 'sampler');
    await expect(option(page, 'sampler', 'retries')).toHaveValue('5');
    await expect(option(page, 'sampler', 'label')).toHaveValue('node');
    await option(page, 'sampler', 'retries').fill('3');
    await checkbox(page, 'sampler', 'verbose').uncheck();
    await saveDialog(page);
    expect((await savedSections(request)).sampler).toEqual(written);
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).sampler).toBeUndefined();
  });

  test('Dismiss drops what the dialog holds', async ({ page, request }) => {
    await h.openSettings(page);
    await h.editCollector(page, 'sampler');
    await option(page, 'sampler', 'retries').fill('9');
    await dismissDialog(page);
    expect(await h.staged(page)).toEqual({});

    await h.editCollector(page, 'sampler');
    await expect(option(page, 'sampler', 'retries')).toHaveValue('');
    await page.keyboard.press('Escape');
    await expect(h.modal(page)).toBeHidden();

    // The config as the package ships it states every setting already: nothing to apply.
    const before = await h.readConfig(request);
    await saveAndApply(page);
    await expect(page.getByText('There are no changes to apply')).toBeVisible();
    expect(await h.readConfig(request)).toBe(before);
    expect((await savedSections(request)).sampler).toBeUndefined();
  });

  test('a switch and the dialog\'s values make one section', async ({ page, request }) => {
    await h.openSettings(page);
    await h.showTab(page, 'collectors');
    await toggle(page, 'textfile').uncheck();
    await h.editCollector(page, 'textfile');
    await option(page, 'textfile', 'directory').fill('/srv/metrics');
    await saveDialog(page);
    await expect(toggle(page, 'textfile')).not.toBeChecked();
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).textfile).toEqual({ '.type': 'collector', enabled: '0', directory: '/srv/metrics' });
  });

  test('a collector that runs programs has the core\'s timeout, written only when it is set', async ({ page, request }) => {
    await h.openSettings(page);
    const dialog = await h.editCollector(page, 'runner');
    const fields = await dialog.locator('.cbi-value[data-option]').evaluateAll((els) => els.map((el) => el.getAttribute('data-option')));
    expect(fields).toEqual([ 'timeout' ]);
    await expect(option(page, 'runner', 'timeout')).toHaveValue('');
    await expect(option(page, 'runner', 'timeout')).toHaveAttribute('placeholder', '5');
    await expect(dialog.locator('.cbi-value[data-option="timeout"] .cbi-value-description')).toContainText('Seconds the programs of this collector get');
    await expect(dialog.locator('.exporter-reads')).toContainText('Runs true.');
    await h.screenshot(page, 'settings-dialog-timeout');
    await option(page, 'runner', 'timeout').fill('2');
    await saveDialog(page);
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).runner).toEqual({ '.type': 'collector', enabled: '1', timeout: '2' });

    // Switched off with no timeout, the section states the switch, and no timeout.
    await h.openSettings(page);
    await h.editCollector(page, 'runner');
    await expect(option(page, 'runner', 'timeout')).toHaveValue('2');
    await option(page, 'runner', 'timeout').fill('');
    await saveDialog(page);
    await toggle(page, 'runner').uncheck();
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).runner).toEqual({ '.type': 'collector', enabled: '0' });

    await h.openSettings(page);
    await h.showTab(page, 'collectors');
    await toggle(page, 'runner').check();
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).runner).toBeUndefined();
  });

  test('the timeout\'s placeholder follows exec_timeout, as the Exporter tab has it', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.openSettings(page);
    await h.editCollector(page, 'runner');
    await expect(option(page, 'runner', 'timeout')).toHaveAttribute('placeholder', '8');
    await dismissDialog(page);

    await h.showTab(page, 'exporter');
    await field(page, 'exec_timeout').fill('12');
    await h.editCollector(page, 'runner');
    await expect(option(page, 'runner', 'timeout')).toHaveAttribute('placeholder', '12');
    await dismissDialog(page);
  });

  test('refuses a timeout or an exec_timeout that is not 1 to 30 seconds, as the exporter would', async ({ page, request }) => {
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await field(page, 'exec_timeout').fill('31');
    await expect(field(page, 'exec_timeout')).toHaveClass(/cbi-input-invalid/);
    await saveAndApply(page);
    await expect(page.locator('#view .alert-message.error li')).toHaveText([ 'Time for programs: expected an integer from 1 to 30, got 31' ]);
    expect(await h.readConfig(request)).toBe(before);
    await field(page, 'exec_timeout').fill('5');

    await h.editCollector(page, 'runner');
    await option(page, 'runner', 'timeout').fill('0');
    await expect(option(page, 'runner', 'timeout')).toHaveClass(/cbi-input-invalid/);
    await h.modal(page).getByRole('button', { name: 'Save', exact: true }).click();
    await expect(h.modal(page).locator('.alert-message.error li')).toHaveText([ 'timeout: expected an integer from 1 to 30, got 0' ]);
    await dismissDialog(page);
    expect(await h.staged(page)).toEqual({});
    expect(await h.readConfig(request)).toBe(before);
  });

  test('changes only the collectors whose rows changed', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.openSettings(page);
    await h.editCollector(page, 'textfile');
    await expect(option(page, 'textfile', 'directory')).toHaveValue('/srv/prom');
    await option(page, 'textfile', 'directory').fill('');
    await saveDialog(page);
    await saveAndApply(page);
    await applied(page);
    const saved = await savedSections(request);
    // The changed row's section states every option; the other, as it was saved, is left.
    expect(saved.textfile).toEqual({ '.type': 'collector', enabled: '0', directory: '/var/prometheus' });
    expect(saved.wifi).toEqual({ '.type': 'collector', stations: '0' });
    expect(saved.main).toEqual({
      '.type': h.CONFIG, enabled: '1', listen_interface: '*', listen_port: '9102', http_keepalive: '0', compress: '1', omit_zero_values: '1',
      exec_timeout: '8', scrape_timeout: '10', collector_budget: '5',
    });
  });

  test('the dialog checks values as they are typed, by the option\'s datatype and as the exporter reads them, and stages nothing it refuses', async ({ page, request }) => {
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await h.editCollector(page, 'sampler');
    await option(page, 'sampler', 'retries').fill('many');
    await expect(option(page, 'sampler', 'retries')).toHaveClass(/cbi-input-invalid/);
    await expect(option(page, 'sampler', 'retries')).toHaveAttribute('data-tooltip', 'Expecting: valid integer value');
    await h.modal(page).getByRole('button', { name: 'Save', exact: true }).click();
    await expect(h.modal(page).locator('.alert-message.error li')).toHaveText([ 'retries: expected an integer, got "many"' ]);
    await expect(h.modal(page)).toBeVisible();
    await dismissDialog(page);

    // LuCI's directory datatype takes any value; the exporter wants an absolute path.
    await h.editCollector(page, 'textfile');
    await option(page, 'textfile', 'directory').fill('srv/prom');
    await expect(option(page, 'textfile', 'directory')).toHaveClass(/cbi-input-invalid/);
    await expect(option(page, 'textfile', 'directory')).toHaveAttribute('data-tooltip', 'expected an absolute path, got "srv/prom"');
    await h.modal(page).getByRole('button', { name: 'Save', exact: true }).click();
    await expect(h.modal(page).locator('.alert-message.error')).toContainText('Nothing was staged: the exporter would refuse these values.');
    await h.screenshot(page, 'settings-dialog-refused');
    await option(page, 'textfile', 'directory').fill('/srv/prom');
    await expect(option(page, 'textfile', 'directory')).not.toHaveClass(/cbi-input-invalid/);
    await dismissDialog(page);

    expect(await h.staged(page)).toEqual({});
    expect(await h.readConfig(request)).toBe(before);
  });

  test('diskstats\' Edit shows device_exclude, its default and help, and takes a regular expression only', async ({ page, request }) => {
    const before = await h.readConfig(request);
    const plugin = await h.ubus(request, h.CONFIG, 'collectors', {});
    const exclude = plugin.collectors.find((c) => c.id == 'diskstats').options.find((o) => o.name == 'device_exclude');
    expect(exclude).toEqual(expect.objectContaining({ type: 'string', datatype: 'regex' }));
    expect(exclude.default).toContain('mtdblock');

    await h.openSettings(page);
    const dialog = await h.editCollector(page, 'diskstats');
    const fields = await dialog.locator('.cbi-value[data-option]').evaluateAll((els) => els.map((el) => el.getAttribute('data-option')));
    expect(fields).toEqual([ 'device_exclude' ]);
    await expect(option(page, 'diskstats', 'device_exclude')).toHaveValue('');
    await expect(option(page, 'diskstats', 'device_exclude')).toHaveAttribute('placeholder', exclude.default);
    await expect(dialog.locator('.cbi-value[data-option="device_exclude"] .cbi-value-description')).toHaveText(exclude.help);

    await option(page, 'diskstats', 'device_exclude').fill('(mmcblk');
    await expect(option(page, 'diskstats', 'device_exclude')).toHaveClass(/cbi-input-invalid/);
    await h.modal(page).getByRole('button', { name: 'Save', exact: true }).click();
    await expect(h.modal(page)).toBeVisible();
    await option(page, 'diskstats', 'device_exclude').fill('^(loop|mtdblock)[0-9]+$');
    await expect(option(page, 'diskstats', 'device_exclude')).not.toHaveClass(/cbi-input-invalid/);
    await h.screenshot(page, 'settings-dialog-diskstats');
    await dismissDialog(page);

    expect(await h.staged(page)).toEqual({});
    expect(await h.readConfig(request)).toBe(before);
  });

  test('marks what the exporter would refuse of the main section, as the ubus object says, and saves nothing', async ({ page, request }) => {
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

  test('says a saved collector section is not valid, as the exporter reads it, and saves nothing until it is fixed', async ({ page, request }) => {
    await h.useConfig(request, 'invalid');
    const before = await h.readConfig(request);
    await h.openSettings(page);
    await h.showTab(page, 'collectors');
    const note = h.collectorRow(page, 'sampler').locator('.exporter-error');
    await expect(note).toHaveText('The saved settings are not valid: CONFIG_INVALID (retries: expected an integer, got "many")');

    await saveAndApply(page);
    await expect(page.locator('#view .alert-message.error li')).toHaveText([ 'sampler retries: expected an integer, got "many"' ]);
    expect(await h.readConfig(request)).toBe(before);

    await h.editCollector(page, 'sampler');
    await expect(option(page, 'sampler', 'retries')).toHaveValue('many');
    await expect(option(page, 'sampler', 'retries')).toHaveClass(/cbi-input-invalid/);
    await option(page, 'sampler', 'retries').fill('');
    await saveDialog(page);
    await expect(note).toHaveCount(0);
    await saveAndApply(page);
    await applied(page);
    expect((await savedSections(request)).sampler).toBeUndefined();
  });
});

test.describe('Services → Prometheus exporter, for a login with the app\'s ACL alone', () => {
  test.afterEach(async ({ request }) => {
    await h.useConfig(request, 'default');
  });

  test('offers every interface to listen on, and saves, without reading the network configuration', async ({ page, request }) => {
    await h.openSettings(page, h.APP_USER);
    expect(await listenChoices(page)).toEqual([ '*', 'lan', 'loopback', 'wan' ]);

    await field(page, 'listen_port').fill('9103');
    await h.editCollector(page, 'wifi');
    await checkbox(page, 'wifi', 'stations').uncheck();
    await saveDialog(page);
    await saveAndApply(page);
    await applied(page);
    const saved = await savedSections(request);
    expect(saved.main.listen_port).toBe('9103');
    expect(saved.wifi).toEqual({ '.type': 'collector', enabled: '1', stations: '0' });

    const sid = await h.sessionOf(request, h.APP_USER);
    expect(h.denied(await h.rawCall(request, sid, 'uci', 'get', { config: 'network' }))).toBe(true);
    expect(h.denied(await h.rawCall(request, sid, 'network.interface', 'dump', {}))).toBe(true);
  });
});
