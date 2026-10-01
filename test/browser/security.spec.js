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
    await expectInert(page);
    await expect(h.collectorRow(page, 'hostile').locator('td').first()).toContainText(h.HOSTILE);
    await expect(page.locator(`[id="widget.cbid.${h.CONFIG}.hostile.note"]`)).toHaveAttribute('placeholder', h.HOSTILE);
  });

  test('on the status page', async ({ page }) => {
    await h.openStatus(page);
    await expectInert(page);
    await expect(h.collectorRow(page, 'hostile').locator('td').nth(4)).toHaveText(`SOURCE_INVALID (${h.HOSTILE})`);
  });

  test('in what the plugin refuses', async ({ page }) => {
    await h.openSettings(page);
    await page.locator(`[id="widget.cbid.${h.CONFIG}.main.listen_port"]`).fill('0');
    await page.locator(`[id="widget.cbid.${h.CONFIG}.sampler.label"]`).fill(h.HOSTILE);
    await page.locator('#view .cbi-page-actions').getByText('Save & Apply', { exact: true }).click();
    await expect(page.locator('#view .alert-message.error')).toBeVisible();
    await expectInert(page);
  });
});
