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

// The columns of a collector's row.
const NAME = 0, RESULT = 1, DURATION = 2, SERVICE = 3;

const ERROR_CODES = 'https://m00qek.github.io/ucode-prometheus-exporter/0.3/reference/error-codes/';

function banner(page, kind) {
  return page.locator(`#view .exporter-banners .alert-message.${kind}`);
}

// The rows as the table has them: module, group and title.
async function rows(page) {
  return page.locator('#view tr[data-collector]').evaluateAll((trs) => trs.map((tr) => ({
    id: tr.getAttribute('data-collector'),
    group: Number(tr.getAttribute('data-group')),
    title: tr.querySelector('td strong').textContent,
  })));
}

// Rewrites the reply of the plugin's status as `edit` has it, as a newer exporter might
// answer.
async function editStatus(page, edit) {
  await page.route(/\/ubus\//, async (route) => {
    const body = JSON.parse(route.request().postData() ?? 'null');
    const calls = [].concat(body ?? []);
    const ours = (c) => c?.method === 'call' && c.params?.[1] === h.CONFIG && c.params?.[2] === 'status';
    if (!calls.some(ours))
      return route.continue();
    const res = await route.fetch();
    const replies = [].concat(await res.json());
    for (const r of replies)
      if (ours(calls.find((c) => c.id === r.id)) && Array.isArray(r.result) && r.result[1])
        edit(r.result[1]);
    await route.fulfill({ response: res, json: Array.isArray(body) ? replies : replies[0] });
  });
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
    await expect(banner(page, 'error')).toHaveCount(0);

    await expect(h.section(page, 'Collectors').locator('th')).toHaveText([ 'Collector', 'Test run', 'Duration', 'Service\'s scrapes' ]);
    await expect(cell(page, 'loadavg', RESULT)).toHaveText('OK');
    await expect(cell(page, 'loadavg', DURATION)).toHaveText(/^\d+ ms$/);
    await expect(cell(page, 'loadavg', SERVICE)).toHaveText('');
    await expect(cell(page, 'sampler', RESULT)).toHaveText('OK');
    await expect(h.section(page, 'Collectors').locator('p.exporter-summary'))
      .toHaveText(/^\d+ failed, \d+ OK, \d+ with nothing to observe, \d+ off\.$/);
    await expect(page.locator('#view .cbi-map-descr')).toContainText('its results can differ from what Prometheus gets');
    await expect(page.locator('#view .cbi-map-descr a')).toHaveAttribute('href', `/cgi-bin/luci/admin/services/${h.CONFIG}`);
    await h.screenshot(page, 'status-running');
  });

  // dnsmasq is enabled here, and does not run: the collector runs, and says why it failed.
  test('says why a collector failed in words, then its error code, linked to what it means', async ({ page }) => {
    await h.openStatus(page);
    const result = cell(page, 'dhcp_leases', RESULT);
    await expect(result.locator('.label')).toHaveText('Failed');
    await expect(result.locator(':scope > div').nth(1)).toHaveText('dnsmasq is enabled, without its lease file (/tmp/dhcp.leases)');
    await expect(result.locator('small').first()).toHaveText('Error code: SOURCE_UNREADABLE');
    await expect(result.getByRole('link', { name: 'SOURCE_UNREADABLE' })).toHaveAttribute('href', ERROR_CODES);
    await expect(result).not.toContainText('SOURCE_UNREADABLE (');
    // What the jail mounts for it, folded away.
    const mounts = result.locator('details');
    await expect(mounts.locator('summary')).toHaveText('Jail mounts (1)');
    await expect(mounts.locator('code')).toBeHidden();
    await mounts.locator('summary').click();
    await expect(mounts.locator('code')).toHaveText([ '/etc/config/dhcp' ]);
    // A collector that did not fail shows none.
    await expect(cell(page, 'runner', RESULT).locator('details')).toHaveCount(0);
    await expect(cell(page, 'runner', RESULT)).not.toContainText('/bin/true');
  });

  test('names the failed collectors in a banner, and counts them', async ({ page }) => {
    await h.openStatus(page);
    const failed = (await rows(page)).filter((r) => r.group === 0);
    expect(failed.map((r) => r.id).sort()).toEqual([ 'dhcp_leases', 'hostile', 'timesync' ]);
    await expect(banner(page, 'warning')).toHaveCount(1);
    await expect(banner(page, 'warning').locator('p').first())
      .toHaveText(`3 collectors failed in the test run: ${failed.map((r) => r.title).join(', ')}.`);
    await expect(banner(page, 'warning').locator('strong')).toHaveText(failed.map((r) => r.title));
    await expect(h.section(page, 'Collectors').locator('p.exporter-summary')).toHaveText(/^3 failed, \d+ OK, 3 with nothing to observe, 0 off\.$/);
    // The hostile collector's title is text.
    expect(await page.evaluate(() => window.__xss)).toBeUndefined();
  });

  test('says in a banner when the exporter is enabled but not running, with where to look', async ({ page, request }) => {
    await h.useService(request, 'stopped');
    await h.openStatus(page);
    const error = banner(page, 'error');
    await expect(error.locator('h4')).toHaveText('The exporter is enabled but not running: Prometheus gets nothing.');
    await expect(error.getByRole('link', { name: 'System → Startup' })).toHaveAttribute('href', '/cgi-bin/luci/admin/system/startup');
    await expect(error.getByRole('link', { name: 'System log' })).toHaveAttribute('href', '/cgi-bin/luci/admin/status/logs');
    // The banner comes before the tables.
    await expect(page.locator('#view .exporter-banners + .cbi-section h3')).toHaveText('Service');
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Not running');
    await expect(serviceRow(page, 'Metrics').locator('td').last()).toHaveText('Not served while the exporter is not running');
    // The test run runs on the router all the same.
    await expect(cell(page, 'loadavg', RESULT)).toHaveText('OK');
    await h.screenshot(page, 'status-stopped');
  });

  test('says in a notice when the exporter is switched off in its settings', async ({ page, request }) => {
    await h.useService(request, 'stopped');
    await h.useConfig(request, 'off');
    await h.openStatus(page);
    await expect(banner(page, 'error')).toHaveCount(0);
    await expect(banner(page, 'notice').first()).toContainText('The exporter is switched off in its settings, so Prometheus gets nothing.');
    await expect(banner(page, 'notice').first().getByRole('link', { name: 'Services → Prometheus exporter' }))
      .toHaveAttribute('href', `/cgi-bin/luci/admin/services/${h.CONFIG}`);
  });

  test('says a collector whose hardware is not there has nothing to observe, in words and not as a label', async ({ page }) => {
    await h.openStatus(page);
    // No ubus object `dsl` here, and no radio.
    await expect(cell(page, 'ltq_dsl', RESULT).locator('.label')).toHaveCount(0);
    await expect(cell(page, 'ltq_dsl', RESULT).locator('em')).toHaveText('Nothing to observe');
    await expect(cell(page, 'ltq_dsl', RESULT).locator('small')).toHaveText('no DSL modem (no dsl on ubus)');
    await expect(cell(page, 'wifi', RESULT)).toContainText('no wireless radios');
    // Nor unbound's package.
    await expect(cell(page, 'unbound', RESULT).locator('small')).toHaveText('unbound is not installed');
    await h.screenshot(page, 'status-nothing-to-observe');
  });

  // The service's ledger quarantines loadavg and left uname out at its last scrape's
  // deadline: the page's own test run is apart from that, and still runs both.
  test('says what the service\'s own scrapes found in a column of its own, apart from the test run', async ({ page, request }) => {
    await h.useState(request, 'quarantine');
    await h.openStatus(page);
    const loadavg = cell(page, 'loadavg', SERVICE);
    await expect(loadavg.locator('.label')).toHaveText('Quarantined');
    await expect(loadavg).toContainText('The service tries it again in 3 scrapes.');
    await expect(loadavg).toContainText('took 7.25 s, over its budget of 5 s');
    await expect(loadavg.getByRole('link', { name: 'COLLECTOR_OVERRUN' })).toHaveAttribute('href', ERROR_CODES);
    await expect(cell(page, 'uname', SERVICE).locator('.label')).toHaveText('Left out at the deadline');
    await expect(cell(page, 'uname', SERVICE)).toContainText('In the service\'s last scrape.');
    await expect(cell(page, 'cpu', SERVICE)).toHaveText('');
    await expect(cell(page, 'loadavg', RESULT)).toHaveText('OK');
    await expect(cell(page, 'uname', RESULT)).toHaveText('OK');
    await expect(banner(page, 'notice')).toHaveCount(1);
    await expect(banner(page, 'notice').locator('p').first()).toHaveText('The service quarantined 1 collector: Load average.');
    await expect(banner(page, 'notice')).toContainText('a restart of the service tries it at once');
    await h.screenshot(page, 'status-service');
  });

  test('says nothing of the service\'s scrapes before it has any', async ({ page }) => {
    await h.openStatus(page);
    await expect(cell(page, 'loadavg', SERVICE)).toHaveText('');
    await expect(banner(page, 'notice')).toHaveCount(0);
  });

  test('lists every installed collector: failed first, then the service\'s, OK, nothing to observe and off, by title', async ({ page, request }) => {
    const plugin = await h.ubus(request, h.CONFIG, 'collectors', {});
    await h.useState(request, 'quarantine');
    await h.useConfig(request, 'custom');
    await h.openStatus(page);
    const shown = await rows(page);
    expect(shown.map((r) => r.id).sort()).toEqual(plugin.collectors.map((c) => c.id).sort());

    const groups = (g) => shown.filter((r) => r.group === g).map((r) => r.id);
    expect(groups(0).sort()).toEqual([ 'dhcp_leases', 'hostile', 'timesync' ]);
    expect(groups(1)).toEqual([ 'uname', 'loadavg' ]);
    expect(groups(2)).toContain('cpu');
    expect(groups(3).sort()).toEqual([ 'ltq_dsl', 'unbound', 'wifi' ]);
    expect(groups(4)).toEqual([ 'textfile' ]);

    // The groups in order, and each sorted by title, as the settings sort them.
    expect(shown.map((r) => r.group)).toEqual(shown.map((r) => r.group).sort((a, b) => a - b));
    for (let g = 0; g <= 4; g++) {
      const titles = shown.filter((r) => r.group === g).map((r) => r.title);
      expect(titles).toEqual(titles.slice().sort((a, b) => a.localeCompare(b, 'en-GB')));
    }
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

  test('says when procd cannot be asked', async ({ page, request }) => {
    await h.useService(request, 'none');
    await h.openStatus(page);
    await expect(serviceRow(page, 'State').locator('td').last()).toContainText('Unknown');
    await expect(serviceRow(page, 'State').locator('td').last()).toContainText('UBUS_CALL_FAILED');
  });

  test('does not run a collector that is switched off, and says so', async ({ page, request }) => {
    await h.useConfig(request, 'custom');
    await h.openStatus(page);
    await expect(cell(page, 'textfile', RESULT)).toHaveText('Not run: switched off');
    await expect(cell(page, 'textfile', DURATION)).toHaveText('');
    await expect(cell(page, 'textfile', RESULT).locator('details')).toHaveCount(0);
    await expect(h.section(page, 'Collectors').locator('p.exporter-summary')).toHaveText(/, 1 off\.$/);
  });

  // A newer exporter may answer error codes this page does not know, errors of another
  // shape, and fields it does not know.
  test('shows an error code it does not know, and an error of another shape, as text', async ({ page }) => {
    await editStatus(page, (reply) => {
      reply.later = { unknown: true };
      for (const c of reply.collectors) {
        if (c.id === 'dhcp_leases')
          c.error = 'COLLECTOR_KILLED (killed after 30 s)';
        if (c.id === 'timesync')
          c.error = 'SAMPLE_LIMIT';
        if (c.id === 'hostile')
          c.error = 'no code at all (<b>really</b>)';
        c.unknown = 1;
      }
    });
    await h.openStatus(page);
    await expect(cell(page, 'dhcp_leases', RESULT)).toContainText('killed after 30 s');
    await expect(cell(page, 'dhcp_leases', RESULT).getByRole('link', { name: 'COLLECTOR_KILLED' })).toHaveAttribute('href', ERROR_CODES);
    await expect(cell(page, 'timesync', RESULT).locator(':scope > div')).toHaveText([ 'Failed', 'Error code: SAMPLE_LIMIT' ]);
    await expect(cell(page, 'hostile', RESULT)).toContainText('no code at all (<b>really</b>)');
    await expect(cell(page, 'hostile', RESULT).locator('b')).toHaveCount(0);
  });

  test('runs again on Refresh, and only then', async ({ page, request }) => {
    await h.openStatus(page);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Running');
    await h.useService(request, 'stopped');
    await page.waitForTimeout(1000);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Running');
    await expect(banner(page, 'error')).toHaveCount(0);
    // A slow answer, so the button can be seen busy.
    await page.route(/\/ubus\//, async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 1500));
      await route.continue();
    });
    const refresh = page.locator('#view').getByRole('button', { name: 'Refresh' });
    await refresh.click();
    await expect(refresh).toBeDisabled();
    await expect(refresh).toHaveClass(/spinning/);
    await expect(serviceRow(page, 'State').locator('td').last()).toHaveText('Not running');
    await expect(refresh).toBeEnabled();
    await expect(banner(page, 'error')).toHaveCount(1);
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
    await expect(cell(page, 'loadavg', RESULT)).toHaveText('OK');
  });
});

// On a phone, bootstrap shows each cell's column heading above it, from data-title: a cell
// with nothing in it has none.
test.describe('Status → Prometheus exporter, at phone width', () => {
  test.use({ viewport: { width: 375, height: 812 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 });

  test.afterEach(async ({ request }) => {
    await h.useState(request, 'none');
    await h.useConfig(request, 'default');
  });

  test('shows no empty headings, and every heading over something', async ({ page, request }) => {
    await h.useState(request, 'quarantine');
    await h.useConfig(request, 'custom');
    await h.openStatus(page);
    // The theme's narrow layout is in force: the table's own headings are hidden.
    await expect(h.section(page, 'Collectors').locator('tr.table-titles')).toBeHidden();

    const cells = await page.locator('#view tr[data-collector] td').evaluateAll((tds) => tds.map((td) => ({
      heading: getComputedStyle(td, '::before').content,
      text: td.textContent.trim(),
    })));
    const shown = (c) => c.heading !== 'none' && c.heading !== 'normal' && c.heading !== '""';
    expect(cells.filter((c) => c.text === '' && shown(c))).toEqual([]);
    expect(cells.filter(shown).length).toBeGreaterThan(0);
    // The collector's name needs none.
    await expect(cell(page, 'cpu', NAME)).not.toHaveAttribute('data-title');
    await expect(cell(page, 'cpu', SERVICE)).not.toHaveAttribute('data-title');
    await expect(cell(page, 'textfile', DURATION)).not.toHaveAttribute('data-title');
    await expect(cell(page, 'loadavg', SERVICE)).toHaveAttribute('data-title', 'Service\'s scrapes');

    // An OK row is two lines of cells, not a page.
    const height = await h.collectorRow(page, 'cpu').evaluate((tr) => tr.getBoundingClientRect().height);
    expect(height).toBeLessThan(130);
    await h.screenshot(page, 'status-phone');
  });
});
