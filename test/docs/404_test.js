// devenv/gh-pages/404.html: the redirect from unversioned links to latest/.
// Runs the page's own script against a fake window.location.
const assert = require("node:assert");
const fs = require("node:fs");
const vm = require("node:vm");

const page = fs.readFileSync(`${__dirname}/../../devenv/gh-pages/404.html`, "utf8");
const script = /<script>([\s\S]*?)<\/script>/.exec(page)[1];

function redirectOf(href) {
  const url = new URL(href, "https://example.github.io");
  let target = null;
  const location = {
    pathname: url.pathname,
    search: url.search,
    hash: url.hash,
    replace: (to) => { target = to; },
  };
  vm.runInNewContext(script, { window: { location } });
  return target;
}

const cases = [
  ["an unversioned deep link keeps its query and anchor",
    "/ucode-prometheus-exporter/how-to/install/?q=spoke#upgrade", "/ucode-prometheus-exporter/latest/how-to/install/?q=spoke#upgrade"],
  ["an unversioned page", "/ucode-prometheus-exporter/reference/uci-config/", "/ucode-prometheus-exporter/latest/reference/uci-config/"],
  ["a file without a trailing slash", "/ucode-prometheus-exporter/sitemap.xml", "/ucode-prometheus-exporter/latest/sitemap.xml"],
  ["the site root", "/ucode-prometheus-exporter/", "/ucode-prometheus-exporter/latest/"],
  ["the site root without a slash", "/ucode-prometheus-exporter", "/ucode-prometheus-exporter/latest/"],
  ["a missing page under latest/ stays", "/ucode-prometheus-exporter/latest/nope/", null],
  ["a missing page under a version stays", "/ucode-prometheus-exporter/0.9/nope/", null],
  ["a missing page under a two-digit minor stays", "/ucode-prometheus-exporter/0.10/nope/", null],
  ["a missing page under dev/ stays", "/ucode-prometheus-exporter/dev/nope/", null],
  ["a version folder itself stays", "/ucode-prometheus-exporter/0.9", null],
  ["the host root stays", "/", null],
  ["a folder that only starts like a version moves", "/ucode-prometheus-exporter/0.9x/", "/ucode-prometheus-exporter/latest/0.9x/"],
];

let failures = 0;
for (const [name, from, to] of cases) {
  try {
    assert.strictEqual(redirectOf(from), to);
    console.log(`ok   ${name}`);
  } catch (e) {
    console.log(`FAIL ${name}: ${from} -> ${redirectOf(from)}, expected ${to}`);
    failures++;
  }
}
process.exit(failures > 0 ? 1 : 0);
