// make monitoring-lab's screenshots: each dashboard, whole, in Grafana and in
// Perses, on the lab's last 15 minutes, into the directory given. Run in the
// browser tests' image (devenv/services/browser), with Playwright and Alpine's
// Chromium. Usage: node screenshots.mjs <directory>
import { chromium } from '/app/node_modules/playwright-core/index.mjs';

const out = process.argv[2];
const grafana = process.env.GRAFANA_URL;
const perses = process.env.PERSES_URL;

const pages = [
	[ 'grafana-openwrt-router', `${grafana}/d/openwrt-router?orgId=1&from=now-15m&to=now&kiosk` ],
	[ 'grafana-exporter-health', `${grafana}/d/openwrt-exporter-health?orgId=1&from=now-15m&to=now&kiosk` ],
	[ 'perses-openwrt-router', `${perses}/projects/openwrt/dashboards/openwrt-router?start=15m` ],
	[ 'perses-exporter-health', `${perses}/projects/openwrt/dashboards/openwrt-exporter-health?start=15m` ],
];

const browser = await chromium.launch({
	executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
	args: [ '--no-sandbox', '--disable-setuid-sandbox' ],
});
// Tall enough for a whole dashboard: Grafana scrolls inside the page, not the page.
const context = await browser.newContext({ viewport: { width: 1600, height: 4200 }, colorScheme: 'dark', locale: 'en-GB' });
let status = 0;

for (const [ name, url ] of pages) {
	const page = await context.newPage();
	try {
		await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
		// Perses draws a panel once it is scrolled into view.
		const height = await page.evaluate(() => document.documentElement.scrollHeight);
		for (let y = 0; y < height; y += 800) {
			await page.evaluate((to) => window.scrollTo(0, to), y);
			await page.waitForTimeout(300);
		}
		await page.evaluate(() => window.scrollTo(0, 0));
		await page.waitForTimeout(3000);
		await page.waitForLoadState('networkidle');
		await page.screenshot({ path: `${out}/${name}.png`, fullPage: true });
		console.log(`${name}.png`);
	} catch (e) {
		console.error(`${name}: ${e.message}`);
		status = 1;
	}
	await page.close();
}

await browser.close();
process.exit(status);
