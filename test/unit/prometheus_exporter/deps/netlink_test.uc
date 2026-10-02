'use strict';

import { describe, it, assert, mock } from 'utest';
import * as deps_netlink from 'prometheus_exporter.deps.netlink';

function brief(res) {
	return res.ok ? { ok: true, data: res.data } : { ok: false, error: res.error, details: res.details };
}

describe('deps.netlink.nl80211_channel', () => {
	it('answers requests as Results and passes the constants through', () => {
		mock.inject('nl80211', {
			strict: true,
			data: { 'NL80211_CMD_GET_INTERFACE:wlan0': { ifname: 'wlan0' }, 'NL80211_CMD_GET_SURVEY': null },
			errors: { 'NL80211_CMD_GET_STATION:wlan0': 'No such device' },
		}, (nl) => {
			let ch = deps_netlink.nl80211_channel(nl);
			let c = ch.const;

			assert.match({ ok: true, data: { ifname: 'wlan0' } }, brief(ch.request(c.NL80211_CMD_GET_INTERFACE, 0, { dev: 'wlan0' })));
			assert.match({ ok: true, data: null }, brief(ch.request(c.NL80211_CMD_GET_SURVEY, c.NLM_F_DUMP, { dev: 'wlan0' })));
			assert.match({ ok: false, error: 'NL80211_FAILED', details: 'No such device' },
				brief(ch.request(c.NL80211_CMD_GET_STATION, c.NLM_F_DUMP, { dev: 'wlan0' })));
		});
	});
});

describe('deps.netlink.rtnl_channel', () => {
	it('answers requests as Results and passes the constants through', () => {
		mock.inject('rtnl', {
			strict: true,
			data: { 'RTM_GETLINK': [ { dev: 'lo', mtu: 65536 } ] },
			errors: { 'RTM_GETLINK:nope': 'No such device' },
		}, (rtnl) => {
			let ch = deps_netlink.rtnl_channel(rtnl);
			let c = ch.const;

			assert.match({ ok: true, data: [ { dev: 'lo', mtu: 65536 } ] }, brief(ch.request(c.RTM_GETLINK, c.NLM_F_DUMP, {})));
			assert.match({ ok: false, error: 'RTNL_FAILED', details: 'No such device' },
				brief(ch.request(c.RTM_GETLINK, 0, { dev: 'nope' })));
		});
	});
});

describe('deps.netlink.load_rtnl and load_nl80211', () => {
	// rtnl's and nl80211's real wiring is lint's to check: utest's generated shims
	// for them do not compile (`export const const`), so here they load as missing.
	it('gives no rtnl or nl80211 when they do not load', () => {
		assert.match([ null, null ], [ deps_netlink.load_rtnl(), deps_netlink.load_nl80211() ]);
	});
});
