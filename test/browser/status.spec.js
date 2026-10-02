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
    await h.useState(request, 'none');
  });

  test('says the exporter runs, where it serves /metrics, and how each collector did', async ({ page, request }) => {
    await h.useService(request, 'running');
    await h.openStatus(page);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Running');
    await expect(serviceRow(page, 'Enabled in the settings').locator('td').last()).toHaveText('Yes');
    await expect(serviceRow(page, 'Starts at boot').locator('td').last()).toHaveText('Yes');
    await expect(serviceRow(page, 'Metrics').locator('a')).toHaveText([ 'http://127.0.0.1:9100/metrics', 'http://[::1]:9100/metrics' ]);
    await expect(serviceRow(page, 'Metrics').locator('td').last()).toContainText('(reachable from the router only)');
    await expect(serviceRow(page, 'Basic auth').locator('td').last()).toHaveText('None');
    await expect(serviceRow(page, 'Compression').locator('td').last()).toHaveText('gzip, when the scraper asks for it');

    await expect(cell(page, 'loadavg', 1)).toHaveText('Yes');
    await expect(cell(page, 'loadavg', 2)).toHaveText('OK');
    await expect(cell(page, 'loadavg', 3)).toHaveText(/^\d+ ms$/);
    await expect(cell(page, 'loadavg', 4)).toHaveText('');
    await expect(cell(page, 'sampler', 2)).toHaveText('OK');
    // dnsmasq is enabled here, and does not run: the collector runs, and says why it failed.
    await expect(cell(page, 'dhcp_leases', 2)).toHaveText('Failed');
    await expect(cell(page, 'dhcp_leases', 4)).toContainText('SOURCE_UNREADABLE (dnsmasq is enabled, without its lease file');
    // wireguard names peers through rpcd, with peer_names: no config of its own.
    await expect(cell(page, 'wireguard', 5)).toHaveText('');
    await expect(cell(page, 'dhcp_leases', 5)).toContainText('/etc/config/dhcp');
    await expect(h.section(page, 'Collectors').locator('p').first())
      .toHaveText(/^\d+ of \d+ collectors that ran succeeded\. \d+ had nothing to observe: their hardware, kernel feature or service is not there\.$/);
    await expect(page.locator('#view .cbi-map-descr a')).toHaveAttribute('href', `/cgi-bin/luci/admin/services/${h.CONFIG}`);
    await h.screenshot(page, 'status-running');
  });

  test('says a collector whose hardware is not there has nothing to observe, and why, as a success', async ({ page }) => {
    await h.openStatus(page);
    // No ubus object `dsl` here, and no radio.
    await expect(cell(page, 'ltq_dsl', 2).locator('.label')).toHaveText('Nothing to observe');
    await expect(cell(page, 'ltq_dsl', 2).locator('small')).toHaveText('no DSL modem (no dsl on ubus)');
    await expect(cell(page, 'ltq_dsl', 4)).toHaveText('');
    await expect(cell(page, 'wifi', 2)).toContainText('no wireless radios');
    // Nor unbound's package.
    await expect(cell(page, 'unbound', 2).locator('small')).toHaveText('unbound is not installed');
    await h.screenshot(page, 'status-nothing-to-observe');
  });

  // The service's ledger quarantines loadavg and left uname out at its last scrape's
  // deadline: the page's own test run is apart from that, and still runs both.
  test('says what the service\'s own scrapes found: a collector quarantined, and one left out at the deadline', async ({ page, request }) => {
    await h.useState(request, 'quarantine');
    await h.openStatus(page);
    await expect(cell(page, 'loadavg', 6).locator('.label')).toHaveText('Quarantined');
    await expect(cell(page, 'loadavg', 6)).toContainText('Tried again in 3 scrapes.');
    await expect(cell(page, 'loadavg', 6)).toContainText('COLLECTOR_OVERRUN (took 7.25 s, over its budget of 5 s)');
    await expect(cell(page, 'uname', 6).locator('.label')).toHaveText('Left out at the deadline');
    await expect(cell(page, 'uname', 6)).toContainText('In the last scrape.');
    await expect(cell(page, 'cpu', 6)).toHaveText('');
    await expect(cell(page, 'loadavg', 2)).toHaveText('OK');
    await expect(cell(page, 'uname', 2)).toHaveText('OK');
    await h.screenshot(page, 'status-service');
  });

  test('says nothing of the service\'s scrapes before it has any', async ({ page }) => {
    await h.openStatus(page);
    await expect(cell(page, 'loadavg', 6)).toHaveText('');
  });

  test('lists every installed collector, as the settings do', async ({ page, request }) => {
    const plugin = await h.ubus(request, h.CONFIG, 'collectors', {});
    await h.openStatus(page);
    const rows = await page.locator('#view tr[data-collector]').evaluateAll((trs) => trs.map((tr) => tr.getAttribute('data-collector')));
    expect(rows).toEqual(plugin.collectors.map((c) => c.id));
  });

  test('says a scrape logs in with basic auth, as configured', async ({ page, request }) => {
    await h.useConfig(request, 'auth');
    await h.openStatus(page);
    await expect(serviceRow(page, 'Basic auth').locator('td').last()).toHaveText('A scrape logs in, over HTTPS');
    expect(await page.content()).not.toContain('$1$$ysVNzQc4CTMkp5daOdZ.3/');
  });

  test('opens /metrics on every address at the address this page came from', async ({ page, request }) => {
    await h.useService(request, 'running-any');
    await h.openStatus(page);
    await expect(serviceRow(page, 'Metrics').locator('a')).toHaveText([ 'https://127.0.0.1:9100/metrics' ]);
    await expect(serviceRow(page, 'Metrics').locator('a')).toHaveAttribute('href', 'https://127.0.0.1:9100/metrics');
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

  test('without the exporter\'s ubus object, says so in words, without a stack trace', async ({ page }) => {
    await h.withoutObject(page);
    await h.openStatus(page);
    await expect(page.locator('#view .alert-message.error')).toHaveText(
      'The status of the exporter could not be read: The exporter\'s ubus object is not available (rpcd may be restarting). Reload in a moment.');
    await expect(page.locator('#view')).not.toContainText('handleCallReply');
    await expect(page.locator('#view')).not.toContainText('No collector is installed.');
  });

  test('works for a login with the app\'s ACL alone', async ({ page }) => {
    await h.openStatus(page, h.APP_USER);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Running');
    await expect(cell(page, 'loadavg', 2)).toHaveText('OK');
  });
});
