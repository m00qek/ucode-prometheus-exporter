'use strict';
'require baseclass';
'require rpc';
'require validation';

const CONFIG = 'prometheus-exporter';

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

const callInterfaces = rpc.declare({
	object: CONFIG,
	method: 'interfaces',
	reject: true
});

const callStatus = rpc.declare({
	object: CONFIG,
	method: 'status',
	reject: true
});

const callPassword = rpc.declare({
	object: CONFIG,
	method: 'password',
	reject: true
});

const callSetPassword = rpc.declare({
	object: CONFIG,
	method: 'set_password',
	params: [ 'password' ],
	reject: true
});

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

const UNAVAILABLE = /failed with (?:error (?:-32000|-32002)|ubus code [34]):/;

function isUnavailable(err) {
	return UNAVAILABLE.test(String(err?.message ?? ''));
}

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

const CORE_TITLES = {
	enabled: _('Enabled'),
	timeout: _('Program timeout'),
	budget: _('Budget'),
	max_samples: _('Sample limit')
};

function optionTitle(c, name) {
	const core = lookup(CORE_TITLES, name);

	if (core != null)
		return core;

	const option = (Array.isArray(c?.options) ? c.options : []).find((o) => o?.name === name);

	return String(option?.title || name);
}

function say(template, ...args) {
	return fill(template, ...args.map((a) => String(a))).join('');
}

const PROBLEMS = {
	BOOLEAN: (p, title) => say(_('%s must be a boolean (1 or 0)'), title),
	INTEGER: (p, title) => say(_('%s must be an integer'), title),
	SINGLE: (p, title) => say(_('%s must be a single value'), title),
	RANGE: (p, title) => say(_('%s must be an integer from %s to %s'), title, p.min, p.max),
	UINTEGER: (p, title) => say(_('%s must be an integer of 0 or more'), title),
	ZERO_OR_MIN: (p, title) => say(_('%s must be 0, or an integer of %s or more'), title, p.min),
	ABSOLUTE_PATH: (p, title) => say(_('%s must be an absolute path'), title),
	OWNED_DIRECTORY: (p, title) => say(_('%s must be a directory under /var, /tmp or /etc/prometheus-exporter'), title),
	TLS_PATH: (p, title) => say(_('%s must be a file under /etc/ssl, /etc/acme or /etc/prometheus-exporter, or uhttpd\'s own /etc/uhttpd.*'), title),
	TLS_FILE: (p, title) => say(_('%s must be a regular file of at most %s bytes, whose links lead nowhere else'), title, p.max),
	REGEX: (p, title) => say(_('%s must be a regular expression'), title),
	USERNAME: (p, title) => say(_('%s must be 1 to 64 characters, without ":", spaces or control characters'), title),
	CRYPT: (p, title) => say(_('%s must be a crypt hash: $1$ (uhttpd -m), $5$ or $6$'), title),
	CRYPT_ROUNDS: (p, title) => say(_('%s must be a hash of at most %s rounds, which a scrape computes to check the password'), title, p.max),
	INTERFACE: (p, title) => say(_('%s must be an interface name, or * for every address'), title),
	AUTH_NEEDS_PASSWORD: (p, title, titleOf) => say(_('%s must be set along with %s'), title, titleOf('auth_user')),
	AUTH_NEEDS_TLS: (p, title, titleOf) =>
		say(_('%s needs HTTPS: set %s and %s, or the password crosses the network in the clear'), title, titleOf('cert'), titleOf('key'))
};

function knowsProblem(refusal) {
	return L.isObject(refusal) && lookup(PROBLEMS, String(refusal.code)) != null;
}

function problemText(refusal, title, titleOf) {
	if (!knowsProblem(refusal))
		return String(L.isObject(refusal) ? (refusal.message ?? refusal.code ?? '') : (refusal ?? ''));

	const sentence = PROBLEMS[refusal.code](refusal, String(title), (name) => String(titleOf?.(name) ?? name));

	return ('value' in refusal) ? say(_('%s, not %s'), sentence, JSON.stringify(refusal.value)) : sentence;
}

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

	password() {
		return callPassword();
	},

	setPassword(password) {
		return callSetPassword(password);
	},

	nameOf(c) {
		return (c.title && c.title !== c.name) ? [ E('strong', {}, [ c.title ]), ' ', E('code', {}, [ c.name ]) ]
			: [ E('strong', {}, [ c.name ]) ];
	}
});
