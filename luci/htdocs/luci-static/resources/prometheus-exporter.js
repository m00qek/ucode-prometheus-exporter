'use strict';
'require baseclass';
'require rpc';
'require validation';

// Shared by the Prometheus exporter's views: the calls of its rpcd plugin, the
// `regex` datatype its collectors' options may name, and helpers for text.
//
// Every string from the router (collector names, help, packages, paths, errors)
// ends up in a text node: E() gets children as arrays only, and fill() puts data
// between the pieces of a translated template instead of formatting it into markup.

// The exporter's uci config, and the object of its rpcd plugin: both take the name
// of its package.
const CONFIG = 'prometheus-exporter';

const callCollectors = rpc.declare({
	object: CONFIG,
	method: 'collectors'
});

const callValidate = rpc.declare({
	object: CONFIG,
	method: 'validate',
	params: [ 'main', 'collectors' ]
});

// Runs a scrape of the enabled collectors on the router, so it is only called on
// request: when the status page opens, and on Refresh.
const callStatus = rpc.declare({
	object: CONFIG,
	method: 'status'
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

	// A collector's title, with its name when that differs.
	nameOf(c) {
		return (c.title && c.title !== c.name) ? [ E('strong', {}, [ c.title ]), ' ', E('code', {}, [ c.name ]) ]
			: [ E('strong', {}, [ c.name ]) ];
	}
});
