/**
 * The uci capability: read-only handles over the configs a collector declares.
 *
 * @module prometheus_exporter_deps_uci
 */

'use strict';

/**
 * A read-only handle over one uci config, as uci_handles makes it: what deps.uci.<config> is.
 *
 * @typedef {{
 *   loaded: () => boolean,
 *   get: (section: string, option: ?string) => ?(string|string[]),
 *   get_all: (section: string) => ?Object,
 *   sections: (stype: ?string) => Object[],
 *   foreach: (stype: ?string, cb: function(Object)) => void
 * }} UciHandle
 */

function uci_handle(cursor_fn, name) {
	let loaded = null;

	function cursor() {
		let c = cursor_fn();

		if (loaded == null)
			loaded = !!c.load(name);

		return c;
	}

	function sections(stype) {
		let c = cursor();
		let found = [];

		if (loaded)
			c.foreach(name, stype, (s) => { push(found, s); });

		return found;
	}

	return {
		loaded: function() {
			cursor();
			return loaded;
		},
		get: function(section, option) {
			let c = cursor();
			return loaded ? c.get(name, section, option) : null;
		},
		get_all: function(section) {
			let c = cursor();
			return loaded ? c.get_all(name, section) : null;
		},
		sections,
		foreach: function(stype, cb) {
			for (let s in sections(stype))
				cb(s);
		},
	};
}

/**
 * Read-only handles over uci configs: { <config>: handle } for each of `configs`.
 *
 * @param {function(): UciCursor} cursor_fn
 * @param {string[]} configs
 * @returns {Object<string, UciHandle>}
 */
export function uci_handles(cursor_fn, configs) {
	let handles = {};

	for (let name in configs)
		handles[name] = uci_handle(cursor_fn, name);

	return handles;
};
