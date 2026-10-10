const { test, expect } = require('@playwright/test');
const { transformSync } = require('esbuild');
const fs = require('fs');

// The package build strips the comments of the app's JavaScript, keeping its
// lines (devenv/scripts/strip-comments.py). What LuCI serves must be its
// source to the token: the same once esbuild drops comments and whitespace.
// LuCI compiles a view as a function body, so it is parsed as one. The
// sources are luci/htdocs, which browser.sh mounts at /app/luci.
const FILES = [
  'luci-static/resources/prometheus-exporter.js',
  'luci-static/resources/prometheus-exporter/widgets.js',
  'luci-static/resources/view/prometheus-exporter/settings.js',
  'luci-static/resources/view/prometheus-exporter/status.js',
];

function tokens(text) {
  return transformSync(`(function(){${text}\n})`, { minifyWhitespace: true, legalComments: 'none', loader: 'js' }).code;
}

test.describe('The app\'s JavaScript as LuCI serves it', () => {
  for (const path of FILES)
    test(`${path} is its source without comments, on as many lines`, async ({ request }) => {
      const source = fs.readFileSync(`/app/luci/${path}`, 'utf8');
      const reply = await request.get(`/${path}`);
      expect(reply.ok()).toBeTruthy();
      const served = await reply.text();

      expect(served.split('\n').length).toBe(source.split('\n').length);
      expect(served).not.toMatch(/^\s*(\/\/|\/\*)/m);
      expect(tokens(served)).toBe(tokens(source));
    });
});
