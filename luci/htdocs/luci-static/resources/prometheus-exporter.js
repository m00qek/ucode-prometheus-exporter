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

// The core's options of a collector by their titles, as the Limits tab has them. The
// collector's own come with the titles it gives them, which LuCI cannot translate: they
// come from the router, as its name and help do, and are shown as they are.
const CORE_TITLES = {
	enabled: _('Enabled'),
	timeout: _('Program timeout'),
	budget: _('Budget'),
	max_samples: _('Sample limit')
};

// The title of option `name` of collector `c`: the core's, translated; the collector's
// own as the ubus object's `collectors` gives it; its name when there is neither.
function optionTitle(c, name) {
	const core = lookup(CORE_TITLES, name);

	if (core != null)
		return core;

	const option = (Array.isArray(c?.options) ? c.options : []).find((o) => o?.name === name);

	return String(option?.title || name);
}

// A translated template with each `%s` filled by text, as a string, for a tooltip or a text
// node: not .format(), whose `%s` would put text where markup may go, and whose `%h` would
// show the escapes of text that stays text.
function say(template, ...args) {
	return fill(template, ...args.map((a) => String(a))).join('');
}

// What the object's validate refuses of a value, by the code of what is wrong, in the
// user's language: a sentence of the field's title and the code's arguments. The exporter
// says the same in English (src/prometheus_exporter/config/problems.uc), which the reply
// holds as `message`; a test holds the two to the same codes. `titleOf(name)` gives the
// title of another field a sentence names.
const PROBLEMS = {
	BOOLEAN: (p, title) => say(_('%s must be a boolean (1 or 0)'), title),
	INTEGER: (p, title) => say(_('%s must be an integer'), title),
	SINGLE: (p, title) => say(_('%s must be a single value'), title),
	RANGE: (p, title) => say(_('%s must be an integer from %s to %s'), title, p.min, p.max),
	UINTEGER: (p, title) => say(_('%s must be an integer of 0 or more'), title),
	ZERO_OR_MIN: (p, title) => say(_('%s must be 0, or an integer of %s or more'), title, p.min),
	ABSOLUTE_PATH: (p, title) => say(_('%s must be an absolute path'), title),
	OWNED_DIRECTORY: (p, title) => say(_('%s must be a directory under /var, /tmp or /etc/prometheus-exporter'), title),
	REGEX: (p, title) => say(_('%s must be a regular expression'), title),
	USERNAME: (p, title) => say(_('%s must be 1 to 64 characters, without ":", spaces or control characters'), title),
	CRYPT: (p, title) => say(_('%s must be a crypt hash: $1$ (uhttpd -m), $5$ or $6$'), title),
	CRYPT_ROUNDS: (p, title) => say(_('%s must be a hash of at most %s rounds, which a scrape computes to check the password'), title, p.max),
	INTERFACE: (p, title) => say(_('%s must be an interface name, or * for every address'), title),
	AUTH_NEEDS_PASSWORD: (p, title, titleOf) => say(_('%s must be set along with %s'), title, titleOf('auth_user')),
	AUTH_NEEDS_USER: (p, title, titleOf) => say(_('%s must be set along with %s'), title, titleOf('auth_password')),
	AUTH_NEEDS_TLS: (p, title, titleOf) =>
		say(_('%s needs HTTPS: set %s and %s, or the password crosses the network in the clear'), title, titleOf('cert'), titleOf('key'))
};

// Whether the page says a refusal of the object's validate in its own words: one of a code
// it knows. The sentence names the field; the English of a code it does not know does not.
function knowsProblem(refusal) {
	return L.isObject(refusal) && lookup(PROBLEMS, String(refusal.code)) != null;
}

// A refusal of the object's validate, { code, ...args, message }, as the page says it: its
// code's sentence, with the field's title, and the value refused when the reply holds it; a
// code the page does not know by the exporter's English, `message`.
function problemText(refusal, title, titleOf) {
	if (!knowsProblem(refusal))
		return String(L.isObject(refusal) ? (refusal.message ?? refusal.code ?? '') : (refusal ?? ''));

	const sentence = PROBLEMS[refusal.code](refusal, String(title), (name) => String(titleOf?.(name) ?? name));

	return ('value' in refusal) ? say(_('%s, not %s'), sentence, JSON.stringify(refusal.value)) : sentence;
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
	optionTitle: optionTitle,
	PROBLEMS: PROBLEMS,
	knowsProblem: knowsProblem,
	problemText: problemText,
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
