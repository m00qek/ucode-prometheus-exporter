const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// The hostile test collector's help, option default and error are markup
// (test/fixtures/luci/collectors/hostile.uc). Markup from the plugin would make an
// <img src="x">, whose failed load runs onerror.
async function expectInert(page) {
  await page.waitForTimeout(500);
  expect(await page.evaluate(() => window.__xss)).toBeUndefined();
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
}

test.describe('Data from the router is shown as text, never markup', () => {
  test('on the settings page', async ({ page }) => {
    await h.openSettings(page);
    await h.showTab(page, 'collectors');
    await expectInert(page);
    await expect(h.collectorRow(page, 'hostile').locator('td').first()).toContainText(`${h.HOSTILE} hostile${h.HOSTILE}`);
  });

  test('in a collector\'s dialog', async ({ page }) => {
    await h.openSettings(page);
    const dialog = await h.editCollector(page, 'hostile');
    await expectInert(page);
    await expect(dialog.locator('h4')).toHaveText(`${h.HOSTILE} hostile`);
    await expect(dialog.locator('.exporter-editor > p').first()).toHaveText(h.HOSTILE);
    await expect(dialog.locator(`[id="widget.cbid.${h.CONFIG}.hostile.note"]`)).toHaveAttribute('placeholder', h.HOSTILE);
    await expect(dialog.locator('.cbi-value[data-option="note"] .cbi-value-description')).toHaveText(h.HOSTILE);
  });

  test('on the status page', async ({ page }) => {
    await h.openStatus(page);
    await expectInert(page);
    const result = h.collectorRow(page, 'hostile').locator('td').nth(1);
    await expect(result.locator(':scope > div')).toHaveText([ 'Failed', h.HOSTILE, 'Error code: SOURCE_INVALID' ]);
    // Its title, in the banner of failed collectors too.
    await expect(page.locator('#view .exporter-banners .alert-message.warning strong', { hasText: h.HOSTILE })).toHaveText(h.HOSTILE);
  });

  test('in what the ubus object refuses', async ({ page }) => {
    await h.openSettings(page);
    const dialog = await h.editCollector(page, 'sampler');
    await dialog.locator(`[id="widget.cbid.${h.CONFIG}.sampler.retries"]`).fill(h.HOSTILE);
    await dialog.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(dialog.locator('.alert-message.error .exporter-line')).toHaveText([ `retries: expected an integer, got "${h.HOSTILE}"` ]);
    await expectInert(page);
    await dialog.getByRole('button', { name: 'Dismiss', exact: true }).click();

    await h.showTab(page, 'exporter');
    await page.locator(`[id="widget.cbid.${h.CONFIG}.main.listen_port"]`).fill('0');
    await page.locator('#view .cbi-page-actions').getByText('Save & Apply', { exact: true }).click();
    await expect(h.saveError(page)).toBeVisible();
    await expect(page.locator('#view .alert-message.error')).toBeVisible();
    await expectInert(page);
  });
});
