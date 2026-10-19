/**
 * The ubus object as rpcd holds it: the collectors' sources at hand, the other methods compiled when called and let go when idle.
 *
 * @module prometheus_exporter_rpc_plugin
 */

'use strict';

/**
 * The rest of the ubus object, compiled: its name and its methods.
 *
 * @typedef {{ object: string, methods: Object<string, { args: Object, call: function(RpcRequest): * }> }} RpcProgram
 */

/**
 * The seconds the other methods' program is held after a call to one of them: a page's calls, and a status scrape's 60.
 *
 * @type {int}
 */
export const IDLE_SECONDS = 120;

function relay(hold, name) {
	return (req) => hold().methods[name].call(req);
}

/**
 * The object rpcd serves: `light`'s methods, and each other of `compile()`'s, compiled when it is called and let go `seconds` after the last call.
 *
 * @param {function(): RpcProgram} compile compiles the rest of the object.
 * @param {Object<string, Object>} light the methods held all along: the sources' (sources.methods()).
 * @param {?function(int, function()): ?{ cancel: function() }} timer uloop's timer(); null holds what it compiled.
 * @param {int} seconds how long after a call what it compiled is held.
 * @returns {Object<string, Object<string, Object>>} the object, by its name, as an rpcd plugin returns it.
 */
export function object(compile, light, timer, seconds) {
	let held = null, clock = null;

	function release() {
		held = null;
		clock = null;
	}

	function hold() {
		held ??= compile();
		clock?.cancel();
		clock = timer ? timer(seconds * 1000, release) : null;
		return held;
	}

	let first = compile();
	let methods = { ...light };

	for (let name, m in first.methods)
		if (!(name in light))
			methods[name] = { args: { ...(m.args ?? {}) }, call: relay(hold, name) };

	return { [first.object]: methods };
};
