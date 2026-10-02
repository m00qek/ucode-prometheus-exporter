'use strict';
'require baseclass';
'require rpc';
'require validation';

// Shared by the Prometheus exporter's views: the calls of its ubus object, which
// the exporter's own package serves through rpcd, the `regex` datatype its
// collectors' options may name, and helpers for text.
//
// Every string from the router (collector names, help, packages, paths, errors)
// ends up in a text node: E() gets children as arrays only, and fill() puts data
// between the pieces of a translated template instead of formatting it into markup.

// The exporter's uci config, and its ubus object: both take the name of its service.
const CONFIG = 'prometheus-exporter';

// Every call rejects when ubus answers other than OK (`reject`), so that a missing object
// or method fails the call as uhttpd's own errors do, and describeError() says why.

const callCollectors = rpc.declare({
	object: CONFIG,
	method: 'collectors',
	reject: true
});

const callValidate = rpc.declare({
	object: CONFIG,
	method: 'validate',
	params: [ 'main', 'collectors' ],
	reject: true
});

// netifd's logical interfaces, by name and protocol: what the listen interface
// takes. The object reads them for a login that may not read the network config.
const callInterfaces = rpc.declare({
	object: CONFIG,
	method: 'interfaces',
	reject: true
});

// Runs a scrape of the enabled collectors on the router, so it is only called on
// request: when the status page opens, and on Refresh.
const callStatus = rpc.declare({
	object: CONFIG,
	method: 'status',
	reject: true
});

// The crypt hash of a password, which auth_password holds: the password never reaches
// the config.
const callHashPassword = rpc.declare({
	object: CONFIG,
	method: 'hash_password',
	params: [ 'password' ],
	reject: true
});

// A regular expression, as vmstat's `fields` takes. The exporter compiles it as a
// POSIX extended regular expression; this only checks it compiles as a JavaScript one,
// which catches unbalanced brackets and the like. The plugin's validate has the last word.
if (typeof(validation.types.regex) !== 'function') {
	validation.types.regex = function() {
		try {
			new RegExp(this.value);
			return this.assert(true);
		}
		catch (e) {
			return this.assert(false, _('a valid regular expression'));
		}
	};
}

// What says the object or its method is not there: uhttpd's JSON-RPC errors for an object
// it cannot find (-32000) and for access it cannot check (-32002: rpcd, which holds the
// sessions, is not answering), and ubus' codes for a method or object not found (3, 4).
// rpcd reloading, or the package being upgraded, has it for a moment.
const UNAVAILABLE = /failed with (?:error (?:-32000|-32002)|ubus code [34]):/;

// Whether a call failed for want of the object, as UNAVAILABLE has it.
function isUnavailable(err) {
	return UNAVAILABLE.test(String(err?.message ?? ''));
}

// What went wrong with a call, for the user: the object's absence in words, an error the
// object answered ({ error, message }) by its message, and any other by the first line of
// its message, without the stack trace LuCI appends to it.
function describeError(err) {
	if (isUnavailable(err))
		return _('The exporter\'s ubus object is not available (rpcd may be restarting). Reload in a moment.');

	if (L.isObject(err) && !(err instanceof Error))
		return String(err.message ?? err.error ?? '');

	return String(err?.message ?? err ?? '').split('\n')[0];
}

function lookup(table, key) {
	return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : null;
}

// The pieces of a translated template with `%s` filled by data, for E(). An argument
// may be a list of pieces itself, such as another fill().
function fill(template, ...args) {
	const parts = template.split('%s');
	const out = [];

	parts.forEach((part, i) => {
		if (part !== '')
			out.push(part);
		if (i < parts.length - 1)
			out.push(...[].concat(args[i] ?? ''));
	});

	return out;
}

// A datatype the page can check: the option's own if LuCI knows it, else one that
// follows from its type. One LuCI does not know is left to the plugin's validate.
function datatypeOf(option) {
	const own = (typeof(option.datatype) === 'string') ? option.datatype : null;

	if (own != null) {
		try {
			validation.compile(own);
			return own;
		}
		catch (e) {
			return null;
		}
	}

	return (option.type === 'int') ? 'integer' : null;
}

// uci's boolean spellings, as the exporter reads them.
function isTrue(value) {
	return [ '1', 'yes', 'on', 'true', 'enabled' ].includes(String(value));
}

function isFalse(value) {
	return [ '0', 'no', 'off', 'false', 'disabled' ].includes(String(value));
}

return baseclass.extend({
	CONFIG: CONFIG,

	lookup: lookup,
	fill: fill,
	isUnavailable: isUnavailable,
	describeError: describeError,
	datatypeOf: datatypeOf,
	isTrue: isTrue,
	isFalse: isFalse,

	collectors() {
		return callCollectors();
	},

	validate(main, collectors) {
		return callValidate(main, collectors);
	},

	status() {
		return callStatus();
	},

	interfaces() {
		return callInterfaces();
	},

	hashPassword(password) {
		return callHashPassword(password);
	},

	// A collector's title, with its name when that differs.
	nameOf(c) {
		return (c.title && c.title !== c.name) ? [ E('strong', {}, [ c.title ]), ' ', E('code', {}, [ c.name ]) ]
			: [ E('strong', {}, [ c.name ]) ];
	}
});
