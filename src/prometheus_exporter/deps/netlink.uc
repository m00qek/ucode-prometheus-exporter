'use strict';

// The rtnl and nl80211 capabilities: a netlink module's requests as Results,
// and the modules themselves, loaded by name at run time.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

// request() of a netlink module (rtnl, nl80211) with its failures as Results,
// `code` naming them; `const` passes through.
function netlink_channel(mod, code) {
	return {
		const: mod.const,
		request: function(cmd, flags, attrs) {
			let reply = mod.request(cmd, flags, attrs);

			return reply === null && mod.error()
				? Result.err(code, mod.error())
				: Result.ok(reply);
		},
	};
}

export function nl80211_channel(mod) {
	return netlink_channel(mod, errors.NL80211_FAILED);
};

export function rtnl_channel(mod) {
	return netlink_channel(mod, errors.RTNL_FAILED);
};

// A netlink module by name as well, loaded at run time: nl80211 is a separate
// package, and a module exporting `const` cannot be imported under utest (its
// generated shim does not compile). Null when it is missing or does not load:
// then only the collectors that need it fail. Lint loads both on 25.12, where a
// missing function would show.
function load_netlink(name) {
	try {
		return loadstring(
			sprintf("import { request, error, 'const' as consts } from %J;\n", name) +
			'return { request, error, const: consts };',
			{ raw_mode: true })();
	} catch (e) {
		return null;
	}
}

export function load_rtnl() {
	return load_netlink('rtnl');
};

export function load_nl80211() {
	return load_netlink('nl80211');
};
