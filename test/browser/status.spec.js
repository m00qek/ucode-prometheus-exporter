const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// Status → Prometheus exporter: the service as the fake procd reports it
// (test/fixtures/luci/service/), and a real scrape of the installed collectors, which
// the plugin runs in the container.

function serviceRow(page, title) {
  return h.section(page, 'Service').locator('tr').filter({ has: page.locator('td', { hasText: new RegExp(`^${title}$`) }) });
}

function cell(page, id, n) {
  return h.collectorRow(page, id).locator('td').nth(n);
}

test.describe('Status → Prometheus exporter', () => {
  test.afterEach(async ({ request }) => {
    await h.useService(request, 'running');
    await h.useConfig(request, 'default');
  });

  test('says the exporter runs, where it serves /metrics, and how each collector did', async ({ page, request }) => {
    await h.useService(request, 'running');
    await h.openStatus(page);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Running');
    await expect(serviceRow(page, 'Enabled in the settings').locator('td').last()).toHaveText('Yes');
    await expect(serviceRow(page, 'Starts at boot').locator('td').last()).toHaveText('Yes');
    await expect(serviceRow(page, 'Metrics').locator('a')).toHaveText([ 'http://127.0.0.1:9101/metrics', 'http://[::1]:9101/metrics' ]);
    await expect(serviceRow(page, 'Metrics').locator('td').last()).toContainText('(reachable from the router only)');

    await expect(cell(page, 'loadavg', 1)).toHaveText('Yes');
    await expect(cell(page, 'loadavg', 2)).toHaveText('OK');
    await expect(cell(page, 'loadavg', 3)).toHaveText(/^\d+ ms$/);
    await expect(cell(page, 'loadavg', 4)).toHaveText('');
    await expect(cell(page, 'sampler', 2)).toHaveText('OK');
    // No ubus object `dsl` here: the collector runs, and says why it failed.
    await expect(cell(page, 'ltq_dsl', 2)).toHaveText('Failed');
    await expect(cell(page, 'ltq_dsl', 4)).toContainText('UBUS_CALL_FAILED');
    await expect(cell(page, 'wireguard', 5)).toHaveText('/etc/config/network');
    await expect(cell(page, 'dhcp_leases', 5)).toContainText('/etc/config/dhcp');
    await expect(h.section(page, 'Collectors').locator('p').first()).toHaveText(/^\d+ of \d+ collectors that ran succeeded\.$/);
    await expect(page.locator('#view .cbi-map-descr a')).toHaveAttribute('href', `/cgi-bin/luci/admin/services/${h.CONFIG}`);
    await h.screenshot(page, 'status-running');
  });

  test('lists every installed collector, as the settings do', async ({ page, request }) => {
    const plugin = await h.ubus(request, h.CONFIG, 'collectors', {});
    await h.openStatus(page);
    const rows = await page.locator('#view tr[data-collector]').evaluateAll((trs) => trs.map((tr) => tr.getAttribute('data-collector')));
    expect(rows).toEqual(plugin.collectors.map((c) => c.id));
  });

  test('opens /metrics on every address at the address this page came from', async ({ page, request }) => {
    await h.useService(request, 'running-any');
    await h.openStatus(page);
    await expect(serviceRow(page, 'Metrics').locator('a')).toHaveText([ 'https://127.0.0.1:9101/metrics' ]);
    await expect(serviceRow(page, 'Metrics').locator('a')).toHaveAttribute('href', 'https://127.0.0.1:9101/metrics');
  });

  test('says the exporter is not running', async ({ page, request }) => {
    await h.useService(request, 'stopped');
    await h.openStatus(page);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Not running');
    await expect(serviceRow(page, 'Metrics').locator('td').last()).toHaveText('Not served while the exporter is not running');
    // The scrape runs on the router all the same.
    await expect(cell(page, 'loadavg', 2)).toHaveText('OK');
    await h.screenshot(page, 'status-stopped');
  });

  test('says when procd cannot be asked', async ({ page, request }) => {
    await h.useService(request, 'none');
    await h.openStatus(page);
    await expect(serviceRow(page, 'State').locator('td').last()).toContainText('Unknown');
    await expect(serviceRow(page, 'State').locator('td').last()).toContainText('UBUS_CALL_FAILED');
  });

  test('does not run a collector that is switched off, and says so', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.openStatus(page);
    await expect(cell(page, 'textfile', 1)).toHaveText('No');
    await expect(cell(page, 'textfile', 2)).toHaveText('Not run');
    await expect(cell(page, 'textfile', 3)).toHaveText('');
    await expect(cell(page, 'textfile', 5)).toHaveText('');
  });

  test('runs again on Refresh, and only then', async ({ page, request }) => {
    await h.openStatus(page);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Running');
    await h.useService(request, 'stopped');
    await page.waitForTimeout(1000);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Running');
    await page.locator('#view').getByRole('button', { name: 'Refresh' }).click();
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Not running');
  });

  test('works for a login with the app\'s ACL alone', async ({ page }) => {
    await h.openStatus(page, h.APP_USER);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Running');
    await expect(cell(page, 'loadavg', 2)).toHaveText('OK');
  });
});
