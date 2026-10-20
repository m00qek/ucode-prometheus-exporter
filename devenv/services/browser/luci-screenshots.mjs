// make luci-screenshots: the LuCI app's pages in the lab (make lab), as the docs
// show them, into the directory given as luci-*.png. Run in the browser tests'
// image, in the lab's network namespace, where LuCI is http://127.0.0.1/ and
// root's password is empty (devenv/services/lab/setup.sh).
// Usage: node luci-screenshots.mjs <directory>
import { chromium } from '/app/node_modules/playwright-core/index.mjs';

const out = process.argv[2];
const base = 'http://127.0.0.1/cgi-bin/luci';

const browser = await chromium.launch({
	executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
	args: [ '--no-sandbox', '--disable-setuid-sandbox' ],
});
const context = await browser.newContext({ viewport: { width: 1100, height: 900 }, colorScheme: 'light', locale: 'en-GB' });
const page = await context.newPage();
page.setDefaultTimeout(30000);

// The page under LuCI's menu, from the element `from` on (past LuCI's own
// notices, such as the lab's empty root password), at most `height` pixels of it.
async function content(name, from, height) {
	const box = await page.locator('#maincontent').boundingBox();
	const top = (await page.locator(from).first().boundingBox()).y;
	await page.screenshot({
		path: `${out}/${name}.png`,
		clip: { x: box.x, y: top, width: box.width, height: Math.min(box.y + box.height - top, height) },
		fullPage: true,
	});
	console.log(`${name}.png`);
}

async function dialog(name) {
	const modal = page.locator('#modal_overlay .modal');
	await modal.waitFor();
	await page.waitForTimeout(500);
	await modal.screenshot({ path: `${out}/${name}.png` });
	console.log(`${name}.png`);
}

async function settings(tab) {
	await page.goto(`${base}/admin/services/prometheus-exporter`, { waitUntil: 'networkidle' });
	const link = page.locator('.cbi-tabmenu a', { hasText: tab }).first();
	await link.waitFor({ timeout: 60000 });
	await link.click();
	await page.waitForTimeout(500);
}

let status = 0;

try {
	await page.goto(`${base}/`, { waitUntil: 'networkidle' });
	await page.fill('input[name="luci_username"]', 'root');
	await page.fill('input[name="luci_password"]', '');
	await page.press('input[name="luci_password"]', 'Enter');
	await page.locator('input[name="luci_password"]').waitFor({ state: 'detached' });

	await settings('General');
	await content('luci-general', '#maincontent h2', 580);

	await settings('Collectors');
	await content('luci-collectors', '#maincontent h2', 560);

	await page.locator('button[title="Edit the options of wifi"]').click();
	await dialog('luci-edit');
	await page.keyboard.press('Escape');

	await settings('HTTPS & login');
	await page.fill('input[id="widget.cbid.prometheus-exporter.main.cert"]', '/etc/uhttpd.crt');
	await page.fill('input[id="widget.cbid.prometheus-exporter.main.key"]', '/etc/uhttpd.key');
	await page.locator('button', { hasText: 'Change password…' }).click();
	await dialog('luci-change-password');
	await page.keyboard.press('Escape');

	await page.goto(`${base}/admin/status/prometheus-exporter`, { waitUntil: 'networkidle' });
	await page.locator('.exporter-summary').waitFor({ timeout: 60000 });
	await content('luci-status', '#maincontent h3', 640);
} catch (e) {
	console.error(e.message);
	status = 1;
}

await browser.close();
process.exit(status);
