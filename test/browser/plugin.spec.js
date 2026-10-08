const { test, expect } = require('@playwright/test');
const h = require('./helpers');

// The exporter's ubus object through rpcd and the app's ACL, and the page's checks of
// the option shapes the exporter's collectors may declare ({ default, help, datatype }),
// which the installed collectors do not use yet.

test.describe('The ubus object, over rpcd', () => {
  test('validates collector options as the exporter reads them, answering what is wrong by its code', async ({ request }) => {
    const res = await h.ubus(request, h.CONFIG, 'validate', {
      main: { http_keepalive: '-1', listen_interface: '*', auth_user: 'prom', auth_password: '$1$$ysVNzQc4CTMkp5daOdZ.3/' },
      collectors: { sampler: { retries: '1.5', verbose: 'maybe', label: 'x' }, wifi: { stations: 'off' } },
    });
    expect(res).toEqual({ ok: false, errors: {
      main: {
        http_keepalive: { code: 'UINTEGER', value: -1, message: 'expected an integer of 0 or more, got -1' },
        auth_user: { code: 'AUTH_NEEDS_TLS', message: 'basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear' },
      },
      collectors: { sampler: {
        retries: { code: 'INTEGER', value: '1.5', message: 'expected an integer, got "1.5"' },
        verbose: { code: 'BOOLEAN', value: 'maybe', message: 'expected a boolean, got "maybe"' },
      } },
    } });
  });

  test('lists netifd\'s interfaces by name and protocol, and nothing else', async ({ request }) => {
    const res = await h.ubus(request, h.CONFIG, 'interfaces', {});
    expect(res).toEqual({ interfaces: [
      { name: 'loopback', proto: 'static' },
      { name: 'lan', proto: 'static' },
      { name: 'wan', proto: 'dhcp' },
    ] });
  });

  test('answers a login with the app\'s ACL, and only the app\'s methods', async ({ request }) => {
    const sid = await h.sessionOf(request, h.APP_USER);
    for (const method of [ 'collectors', 'validate', 'status', 'interfaces' ])
      expect((await h.rawCall(request, sid, h.CONFIG, method, {})).result?.[0], method).toBe(0);
    expect(h.denied(await h.rawCall(request, sid, 'exporter.fixture', 'read', {}))).toBe(true);
    expect(h.denied(await h.rawCall(request, sid, 'uci', 'get', { config: 'network' }))).toBe(true);
    expect(h.denied(await h.rawCall(request, sid, 'uci', 'get', { config: h.CONFIG }))).toBe(false);
  });
});

test.describe('The page\'s datatypes', () => {
  test('checks a regex option, and follows an option\'s type and datatype', async ({ page }) => {
    await h.openSettings(page);
    const out = await page.evaluate(async () => {
      const validation = await L.require('validation');
      const exporter = await L.require('prometheus-exporter');
      const check = (type, value) => {
        const input = document.createElement('input');
        document.body.appendChild(input);
        input.value = value;
        const ok = validation.create(input, type, false).validate();
        input.remove();
        return ok;
      };
      return {
        regex: [ check('regex', '^pg(in|out)$'), check('regex', '(unclosed'), check('regex', '[a-z') ],
        datatypes: [
          exporter.datatypeOf({ type: 'int', datatype: null }),
          exporter.datatypeOf({ type: 'int', datatype: 'uinteger' }),
          exporter.datatypeOf({ type: 'string', datatype: 'regex' }),
          exporter.datatypeOf({ type: 'string', datatype: 'directory' }),
          exporter.datatypeOf({ type: 'string', datatype: 'range(1,10)' }),
          exporter.datatypeOf({ type: 'string', datatype: 'no_such_type' }),
          exporter.datatypeOf({ type: 'string', datatype: null }),
          exporter.datatypeOf({ type: 'bool', datatype: null }),
        ],
      };
    });
    expect(out.regex).toEqual([ true, false, false ]);
    expect(out.datatypes).toEqual([ 'integer', 'uinteger', 'regex', 'directory', 'range(1,10)', null, null, null ]);
  });
});
