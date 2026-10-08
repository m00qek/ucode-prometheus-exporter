/**
 * The rtnl and nl80211 capabilities: a netlink module's requests as Results,
 * and the modules themselves, loaded by name at run time.
 *
 * @module prometheus_exporter_deps_netlink
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

/**
 * deps.rtnl and deps.nl80211: a netlink module's request() as a Result of its
 * reply, and its constants. The reply is whatever the module decodes of the
 * kernel's answer to `cmd`.
 *
 * @typedef {{
 *   const: Object<string, int>,
 *   request: (cmd: int, flags: ?int, attrs: ?Object) => Result
 * }} NetlinkCapability
 */

/**
 * A netlink module as load_rtnl and load_nl80211 load it: its request,
 * error and constants.
 *
 * @typedef {{ request: function(int, ?int, ?Object): *, error: function(): ?string, const: Object<string, int> }} NetlinkModule
 */

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

/**
 * The nl80211 capability over the nl80211 module: its failures are
 * NL80211_FAILED.
 *
 * @param {NetlinkModule} mod load_nl80211's, or a test's.
 * @returns {NetlinkCapability} deps.nl80211.
 */
export function nl80211_channel(mod) {
	return netlink_channel(mod, errors.NL80211_FAILED);
};

/**
 * The rtnl capability over the rtnl module: its failures are RTNL_FAILED.
 *
 * @param {NetlinkModule} mod load_rtnl's, or a test's.
 * @returns {NetlinkCapability} deps.rtnl.
 */
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

/**
 * The rtnl module, loaded by name at run time (load_netlink).
 *
 * @returns {?NetlinkModule} its request, error and const; null when it does
 *   not load.
 */
export function load_rtnl() {
	return load_netlink('rtnl');
};

/**
 * The nl80211 module, loaded by name at run time (load_netlink): a separate
 * package.
 *
 * @returns {?NetlinkModule} its request, error and const; null when it is
 *   not installed or does not load.
 */
export function load_nl80211() {
	return load_netlink('nl80211');
};
