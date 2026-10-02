'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require prometheus-exporter as exporter';

// Services → Prometheus exporter: /etc/config/prometheus-exporter as a form, in two tabs.
// Exporter has the main section's options. Collectors has a row per installed collector, as
// the ubus object's `collectors` lists them: its title and help, its package, its switch,
// and, when it has options, an Edit button. Edit opens a dialog with a field per option
// (the collector's own, and the core's timeout when it runs programs), whose Save stages
// them in uci, as LuCI's own dialogs do; the page's Save & Apply applies them with the
// rest, and Dismiss drops them.
//
// What is saved states every setting: the main section's fields write their values even
// at the defaults (but for the TLS files and basic auth, which are unset without them).
// Basic auth's password is never saved, nor shown: Save hashes a password typed in its
// field through the object's hash_password, and saves the hash; an empty field keeps the
// saved one, and a user emptied takes basic auth away, hash and all. A collector's
// `config collector '<module>'` section is there only while something differs from the
// defaults, its switch included, or a timeout is set; while it is, it holds the switch
// and every option the collector declares, each written out. timeout is written only
// when it is set: unset, it follows the collector's own default or the main section's
// exec_timeout, which writing it would pin.
//
// The object's `validate` checks values as the exporter reads them: the main section's
// while they are typed and again before Save, a dialog's while they are typed and again
// before it stages them. Nothing the exporter would refuse is saved.
//
// Collector names and help, package names, interfaces and paths come from the router: they
// reach E() only inside arrays, and never a form title or description, which LuCI renders
// as markup.

const CONFIG = exporter.CONFIG;
const lookup = exporter.lookup;
const fill = exporter.fill;

// How long typing pauses before the values are checked, in ms.
const CHECK_DELAY = 300;

// What the object's validate is given for a password typed and not yet hashed: a hash of
// the form hash_password makes (1000 rounds, which auth_password takes; one that names
// none has 5000, which it refuses), so that the options that go with it are checked.
const PENDING_HASH = '$6$rounds=1000$$' + '.'.repeat(86);

// The longest password the object hashes, in bytes.
const PASSWORD_MAX = 256;

function alertBox(kind, children) {
	return E('div', { 'class': 'alert-message ' + kind }, children);
}

function joined(items, separator) {
	const out = [];

	items.forEach((item, i) => {
		if (i > 0)
			out.push(separator);
		out.push(item);
	});

	return out;
}

function codes(items) {
	return joined(items.map((item) => E('code', {}, [ String(item) ])), ', ');
}

// The core's switch, as an option of a collector's section.
const ENABLED = { name: 'enabled', core: true, type: 'bool', default: true };

// Whether a value is unset: uci holds no empty values.
function blank(value) {
	return value == null || value === '';
}

// Whether an option overrides a default kept elsewhere: the core's timeout, which follows
// the collector's meta.timeout or the main section's exec_timeout while it is unset. It is
// written only when it is set.
function isOverride(o) {
	return o.core === true && o.name !== 'enabled';
}

// What a collector's switch holds: on when unset or true, as the exporter takes it, off
// when false, and invalid otherwise.
function switchState(value) {
	if (value == null || exporter.isTrue(value))
		return 'on';

	return exporter.isFalse(value) ? 'off' : 'invalid';
}

// An interface as the picker shows it: its name, and its protocol when known.
function ifaceBadge(name, proto) {
	return E('span', { 'class': 'ifacebadge' }, proto ? [ name, ' ', E('small', {}, [ `(${proto})` ]) ] : [ name ]);
}

// The listen interface: the logical interfaces the ubus object's `interfaces` lists, which
// it reads for any login allowed the object, and every address (*), as the init script
// takes it. A saved value it does not list is kept.
const ListenSelect = form.ListValue.extend({
	__name__: 'CBI.PrometheusExporterListen',

	__init__(...args) {
		this.super('__init__', args);
		this.interfaces = [];
	},

	renderWidget(section_id, option_index, cfgvalue) {
		const value = (cfgvalue != null && cfgvalue !== '') ? cfgvalue : this.default;
		const choices = { '*': E('em', {}, [ _('Every address') ]) };

		for (const iface of this.interfaces)
			if (typeof(iface?.name) === 'string' && iface.name !== '' && iface.name !== '__proto__' && !lookup(choices, iface.name))
				choices[iface.name] = ifaceBadge(iface.name, (typeof(iface.proto) === 'string') ? iface.proto : null);

		if (!lookup(choices, value))
			choices[value] = ifaceBadge(value, null);

		const widget = new ui.Dropdown(value, choices, {
			id: this.cbid(section_id),
			sort: true,
			optional: false,
			disabled: (this.readonly != null) ? this.readonly : this.map.readonly,
			datatype: 'or(uciname,"*")',
			validate: L.bind(this.validate, this, section_id)
		});

		return widget.render();
	}
});

// Basic auth's password. The field holds what is typed, never the saved hash; Save hashes
// it through the object's hash_password and writes the hash. Left empty, the saved hash
// stays; without a user, there is no basic auth and the hash goes. `user` is the option of
// basic auth's user.
const PasswordValue = form.Value.extend({
	__name__: 'CBI.PrometheusExporterPassword',

	cfgvalue(section_id) {
		return null;
	},

	// The hash saved, as uci holds it with staged changes.
	saved(section_id) {
		return uci.get(CONFIG, section_id, 'auth_password');
	},

	renderWidget(section_id, option_index, cfgvalue) {
		this.placeholder = blank(this.saved(section_id)) ? '' : _('Unchanged');
		return this.super('renderWidget', [ section_id, option_index, cfgvalue ]);
	},

	// Writes nothing of what is typed: the hash of it, or nothing.
	parse(section_id) {
		const typed = this.formvalue(section_id);

		if (blank(this.user.formvalue(section_id))) {
			if (this.saved(section_id) != null)
				uci.unset(CONFIG, section_id, 'auth_password');
			return Promise.resolve();
		}

		if (!this.isValid(section_id))
			return Promise.reject(new TypeError(_('Basic auth password:') + ' ' + this.getValidationError(section_id)));

		if (blank(typed))
			return Promise.resolve();

		return exporter.hashPassword(typed).then((res) => {
			if (!L.isObject(res) || typeof(res.hash) !== 'string')
				throw new Error(_('The password could not be hashed:') + ' ' + String(res?.message ?? res?.error ?? ''));

			uci.set(CONFIG, section_id, 'auth_password', res.hash);
		});
	}
});

// A row per installed collector: its title and help, its package, its switch and, when it
// has options, an Edit button that opens them in a dialog. The switches are the form's:
// Save writes those that changed. The dialog stages its own values when it is saved.
const CollectorTable = form.Value.extend({
	__name__: 'CBI.PrometheusExporterCollectors',

	__init__(...args) {
		this.super('__init__', args);
		this.collectors = [];
		this.rows = [];
		this.editor = null;
	},

	// The collector's own section, as LuCI has it with staged changes; null when there is
	// none, or the name is taken by a section of another type, which the exporter ignores.
	sectionOf(id) {
		const s = uci.get(CONFIG, id);
		return (L.isObject(s) && s['.type'] === 'collector') ? s : null;
	},

	// The section's values as uci holds them, empty ones left out, as unset.
	rawValues(id) {
		const section = this.sectionOf(id) ?? {};
		const out = {};

		for (const name in section)
			if (name.charAt(0) !== '.' && section[name] !== '')
				out[name] = section[name];

		return out;
	},

	cfgvalue(section_id) {
		return null;
	},

	renderWidget(section_id, option_index, cfgvalue) {
		const headers = [ _('Collector'), _('Package'), _('Enabled'), '' ];

		this.rows = this.collectors.map((c, i) => this.renderRow(c, i, headers));

		const body = this.rows.length ? this.rows.map((row) => row.node) : [
			E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': String(headers.length) }, [ E('em', {}, [ _('No collector is installed.') ]) ])
			])
		];

		return E('table', { 'class': 'table cbi-section-table', 'id': this.cbid(section_id) }, [
			E('tr', { 'class': 'tr table-titles' }, headers.map((h, i) =>
				E('th', { 'class': (i === headers.length - 1) ? 'th cbi-section-actions' : 'th' }, [ h ])))
		].concat(body));
	},

	renderRow(c, i, headers) {
		const readonly = this.map.readonly;
		const row = { c: c, note: E('div', {}, this.errorNote(c.error)), node: null };

		// An invalid value shows as on, as the exporter would take it once it is fixed.
		row.enabled = new ui.Checkbox(switchState(this.sectionOf(c.id)?.enabled) === 'off' ? '0' : '1',
			{ id: `cbid.${CONFIG}.${c.id}.enabled`, disabled: readonly });

		const toggle = row.enabled.render();
		toggle.querySelector('input').setAttribute('aria-label', fill(_('Enable %s'), c.name).join(''));

		const edit = (c.options ?? []).length ? E('button', {
			'class': 'cbi-button cbi-button-edit',
			'title': fill(_('Edit the options of %s'), c.name).join(''),
			'disabled': readonly ? '' : null,
			'click': ui.createHandlerFn(this, 'openEditor', row)
		}, [ _('Edit') ]) : '';

		row.node = E('tr', { 'class': 'tr cbi-section-table-row cbi-rowstyle-' + (1 + i % 2), 'data-collector': c.id }, [
			E('td', { 'class': 'td', 'data-title': headers[0] }, [
				...exporter.nameOf(c), E('br'), E('small', {}, [ String(c.help ?? '') ]), row.note
			]),
			E('td', { 'class': 'td', 'data-title': headers[1] }, [ this.packageOf(c) ]),
			E('td', { 'class': 'td', 'data-title': headers[2] }, [ toggle ]),
			E('td', { 'class': 'td cbi-section-actions' }, [ edit ])
		]);

		return row;
	},

	// The base package, the removable package that installed it, or none.
	packageOf(c) {
		if (c.base === true)
			return E('span', {}, [ _('base') ]);

		return c.package ? E('code', { 'style': 'white-space:nowrap' }, [ String(c.package) ]) : E('em', {}, [ _('none') ]);
	},

	errorNote(error) {
		return error ? [ E('small', { 'class': 'exporter-error', 'style': 'color:var(--error-color-high,#c43c35)' },
			fill(_('The saved settings are not valid: %s'), String(error))) ] : [];
	},

	// What the collector reads, and what its jail gives it.
	reads(c) {
		const lines = [];
		const mounts = c.jail?.mounts ?? [];

		if ((c.configs ?? []).length)
			lines.push(fill(_('Reads %s.'), codes(c.configs.map((name) => `/etc/config/${name}`))));

		if ((c.commands ?? []).length)
			lines.push(fill(_('Runs %s.'), codes(c.commands)));

		lines.push(mounts.length
			? fill(_('Its jail mounts, as saved: %s.'), codes(mounts))
			: [ _('Its jail mounts nothing for it but what every collector gets: procfs, sysfs, ubus and the log.') ]);

		for (const problem of (c.jail?.problems ?? []))
			lines.push(fill(_('Jail: %s'), String(problem)));

		return lines.map((line) => E('p', {}, [ E('small', {}, line) ]));
	},

	// The dialog of a collector's options: a field per option, by its type, with its help,
	// which the object's validate checks as it is typed; and what the collector reads.
	openEditor(row) {
		const c = row.c;
		const section = this.sectionOf(c.id);
		const editor = { row: row, fields: [], marks: {}, seq: 0, timer: null, problem: E('div', {}, []) };
		const fields = (c.options ?? []).map((o) => this.renderField(editor, o, section));

		editor.node = E('div', { 'class': 'exporter-editor', 'data-collector': c.id }, [
			E('p', {}, [ String(c.help ?? '') ]),
			E('div', { 'class': 'cbi-section' }, [ E('div', { 'class': 'cbi-section-node' }, fields) ]),
			E('div', { 'class': 'exporter-reads' }, this.reads(c)),
			editor.problem,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, 'dismissEditor', editor) }, [ _('Dismiss') ]),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-positive important',
					'disabled': this.map.readonly ? '' : null,
					'click': ui.createHandlerFn(this, 'saveEditor', editor)
				}, [ _('Save') ])
			])
		]);

		editor.node.addEventListener('input', () => this.scheduleEditorCheck(editor));
		editor.node.addEventListener('widget-change', () => this.scheduleEditorCheck(editor));

		this.editor = editor;
		ui.showModal(exporter.nameOf(c), [ editor.node ], 'cbi-modal');
		this.checkEditor(editor);
	},

	renderField(editor, o, section) {
		const c = editor.row.c;
		const raw = (section != null) ? section[o.name] : null;
		const id = `cbid.${CONFIG}.${c.id}.${o.name}`;
		let widget;

		if (o.type === 'bool') {
			const checked = (raw == null) ? o.default === true : exporter.isTrue(raw);
			widget = new ui.Checkbox(checked ? '1' : '0', { id: id, disabled: this.map.readonly });
		}
		else {
			widget = new ui.Textfield((typeof(raw) === 'string') ? raw : '', {
				id: id,
				optional: true,
				placeholder: this.placeholderOf(o),
				datatype: exporter.datatypeOf(o),
				disabled: this.map.readonly,
				// A failed check marks the field until its value changes.
				validate: (value) => {
					const mark = lookup(editor.marks, o.name);
					return (mark && mark.value === value) ? mark.message : true;
				}
			});
		}

		const node = widget.render();
		const input = node.querySelector('input:not([type="hidden"])');

		if (input)
			input.setAttribute('aria-label', fill(_('%s of %s'), o.name, c.name).join(''));

		editor.fields.push({ option: o, widget: widget });

		return E('div', { 'class': 'cbi-value', 'data-option': o.name }, [
			E('label', { 'class': 'cbi-value-title', 'for': input?.id ?? null }, [ o.name ]),
			E('div', { 'class': 'cbi-value-field' }, [ node ].concat(o.help
				? [ E('div', { 'class': 'cbi-value-description' }, [ String(o.help) ]) ] : []))
		]);
	},

	// What an empty field stands for: the option's default. The timeout of a collector
	// without a default of its own follows exec_timeout, as the Exporter tab has it now.
	placeholderOf(o) {
		if (o.core && o.default_from === 'exec_timeout' && typeof(this.execTimeout) === 'function') {
			const own = this.execTimeout();
			if (/^[0-9]+$/.test(own ?? ''))
				return own;
		}

		return String(o.default ?? '');
	},

	// What a dialog's fields hold: '1' or '0' for a switch, the text of a text field.
	editorValues(editor) {
		const out = {};

		for (const f of editor.fields)
			out[f.option.name] = (f.option.type === 'bool') ? (f.widget.getValue() === '1' ? '1' : '0') : f.widget.getValue();

		return out;
	},

	scheduleEditorCheck(editor) {
		window.clearTimeout(editor.timer);
		editor.timer = window.setTimeout(() => this.checkEditor(editor), CHECK_DELAY);
	},

	// Resolves to { ok, errors } of the dialog's values, or to null when there is no answer;
	// an answer to an earlier check than the last is dropped.
	checkEditor(editor) {
		const seq = ++editor.seq;
		const id = editor.row.c.id;
		const values = this.editorValues(editor);
		const given = {};

		window.clearTimeout(editor.timer);

		for (const name in values)
			if (values[name] !== '')
				given[name] = values[name];

		return exporter.validate({}, { [id]: given }).then((res) => {
			if (seq !== editor.seq)
				return null;

			if (!L.isObject(res) || !L.isObject(res.errors)) {
				this.showEditorProblem(editor, [ _('The options could not be checked:'), ' ', String(res?.message ?? res?.error ?? '') ]);
				return null;
			}

			const errors = L.isObject(res.errors.collectors) ? (lookup(res.errors.collectors, id) ?? {}) : {};

			editor.marks = {};
			for (const name in errors)
				editor.marks[name] = { value: values[name] ?? '', message: String(errors[name]) };

			for (const f of editor.fields)
				if (f.option.type !== 'bool')
					f.widget.triggerValidation();

			dom.content(editor.problem, []);
			return { ok: !Object.keys(errors).length, errors: errors };
		}, (err) => {
			if (seq === editor.seq)
				this.showEditorProblem(editor, [ _('The options could not be checked:'), ' ', String(err?.message ?? err) ]);
			return null;
		});
	},

	showEditorProblem(editor, children) {
		dom.content(editor.problem, alertBox('error', children));
	},

	dismissEditor(editor) {
		editor.seq++;
		window.clearTimeout(editor.timer);
		this.editor = null;
		ui.hideModal();
	},

	// Stages the dialog's values in uci when the exporter would take them all; the page's
	// Save & Apply applies them.
	saveEditor(editor) {
		const c = editor.row.c;

		return this.checkEditor(editor).then((res) => {
			if (res == null)
				return null;

			const refused = [];

			for (const f of editor.fields) {
				const name = f.option.name;
				const message = lookup(res.errors, name) ?? (f.widget.isValid() ? null : f.widget.getValidationError());

				if (message != null)
					refused.push(E('li', {}, [ E('code', {}, [ name ]), ': ', String(message) ]));
			}

			if (refused.length) {
				this.showEditorProblem(editor, [
					E('p', {}, [ _('Nothing was staged: the exporter would refuse these values.') ]),
					E('ul', {}, refused)
				]);
				return null;
			}

			// The switch as it is on the page: the section is written whole.
			const values = { ...this.editorValues(editor), enabled: editor.row.enabled.getValue() === '1' ? '1' : '0' };

			if (!this.stage(c, values)) {
				this.showEditorProblem(editor, fill(_('The configuration has a section %s of another type, which the exporter ignores: nothing was staged.'),
					E('code', {}, [ c.id ])));
				return null;
			}

			return uci.save().then(() => {
				editor.seq++;
				this.editor = null;
				ui.hideModal();
				return this.refreshNote(editor.row);
			}, (err) => {
				this.showEditorProblem(editor, [ _('The options could not be staged:'), ' ', String(err?.message ?? err) ]);
				return null;
			});
		});
	},

	// Drops the note that the saved settings are not valid once the staged ones are.
	refreshNote(row) {
		return exporter.validate({}, { [row.c.id]: this.rawValues(row.c.id) }).then((res) => {
			if (L.isObject(res) && res.ok === true)
				dom.content(row.note, []);
		}).catch(() => null);
	},

	// The options a collector's section holds: the switch, its own, and the core's timeout
	// when it runs programs.
	declared(c) {
		return [ ENABLED, ...(c.options ?? []) ];
	},

	// An option's default as uci holds it.
	defaultOf(o) {
		return (o.type === 'bool') ? (o.default === true ? '1' : '0') : String(o.default ?? '');
	},

	// Whether a value, as uci holds it, is the option's default; an unset one is. A value the
	// exporter would not read is not.
	isDefault(o, value) {
		if (blank(value))
			return true;

		switch (o.type) {
		case 'bool':
			return (o.default === true) ? exporter.isTrue(value) : exporter.isFalse(value);
		case 'int':
			return /^-?[0-9]+$/.test(value) && +value === o.default;
		default:
			return value === o.default;
		}
	},

	// Stages `changes` ({ option: value as uci holds it, '' or null to unset }) of the
	// collector's switch and options in LuCI's uci. The section is there while a value
	// differs from its default, a timeout is set, or it holds options nobody declared (which
	// are kept); it then holds the switch and every option the collector declares, each
	// written out, and a timeout only when one is set. It goes once nothing is left. False
	// when the name is another type's section, which is not ours to change.
	stage(c, changes) {
		const id = c.id;
		const named = uci.get(CONFIG, id);

		if (L.isObject(named) && named['.type'] !== 'collector')
			return false;

		const values = { ...this.rawValues(id), ...changes };
		const declared = this.declared(c);
		const names = declared.map((o) => o.name);
		const undeclared = Object.keys(values).filter((k) => !names.includes(k) && !blank(values[k]));
		const needed = undeclared.length > 0 || declared.some((o) =>
			isOverride(o) ? !blank(values[o.name]) : !this.isDefault(o, values[o.name]));

		if (!needed) {
			if (named)
				uci.remove(CONFIG, id);
			return true;
		}

		if (!named)
			uci.add(CONFIG, 'collector', id);

		for (const o of declared) {
			const value = blank(values[o.name]) ? (isOverride(o) ? null : this.defaultOf(o)) : String(values[o.name]);

			if (value == null) {
				if (uci.get(CONFIG, id, o.name) != null)
					uci.unset(CONFIG, id, o.name);
			}
			else if (uci.get(CONFIG, id, o.name) !== value) {
				uci.set(CONFIG, id, o.name, value);
			}
		}

		return true;
	},

	// The collectors' values as the object's validate takes them: each section as uci holds
	// it, staged values included, with the switch as it is on the page.
	candidate() {
		const out = {};

		for (const row of this.rows)
			out[row.c.id] = { ...this.rawValues(row.c.id), enabled: row.enabled.getValue() === '1' ? '1' : '0' };

		return out;
	},

	formvalue(section_id) {
		return this.candidate();
	},

	isValid(section_id) {
		return true;
	},

	getValidationError(section_id) {
		return '';
	},

	triggerValidation(section_id) {
		return false;
	},

	// Writes the switches that differ from their sections.
	parse(section_id) {
		for (const row of this.rows) {
			const on = row.enabled.getValue() === '1';

			if (switchState(this.sectionOf(row.c.id)?.enabled) !== (on ? 'on' : 'off'))
				this.stage(row.c, { enabled: on ? '1' : '0' });
		}

		return Promise.resolve();
	}
});

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(exporter.collectors(), null),
			L.resolveDefault(exporter.interfaces(), null),
			uci.load(CONFIG)
		]);
	},

	render([ data, ifaces ]) {
		// The form edits the main section: a config without one gets it, as the exporter
		// reads a missing one, every option at its default.
		if (uci.get(CONFIG, 'main') == null)
			uci.add(CONFIG, CONFIG, 'main');

		const m = new form.Map(CONFIG);
		const s = m.section(form.NamedSection, 'main', CONFIG);

		this.map = m;
		this.mainOptions = {};
		this.marks = {};
		this.checkSeq = 0;
		this.checkTimer = null;

		s.tab('exporter', _('Exporter'));
		s.tab('collectors', _('Collectors'),
			_('A collector that is switched off is not served. Edit opens its options: Save there stages them, and Save & Apply applies them. A collector has a section in the configuration only while something differs from its defaults; the section then states every option.'));

		this.renderMain(s, (L.isObject(ifaces) && Array.isArray(ifaces.interfaces)) ? ifaces.interfaces : []);

		this.table = s.taboption('collectors', CollectorTable, '_collectors', '');
		this.table.collectors = Array.isArray(data?.collectors) ? data.collectors : [];
		this.table.execTimeout = () => this.mainOptions.exec_timeout?.formvalue('main');

		this.panel = E('div', {}, []);

		return m.render().then((node) => {
			node.addEventListener('widget-change', () => this.scheduleCheck());
			node.addEventListener('input', () => this.scheduleCheck());
			this.scheduleCheck(0);

			return E([], [
				E('h2', { 'name': 'content' }, [ _('Prometheus exporter') ]),
				E('div', { 'class': 'cbi-map-descr' }, [
					_('Node metrics for Prometheus, served at /metrics.'), ' ',
					_('Whether it runs, and how each collector did, is under'), ' ',
					E('a', { 'href': L.url('admin/status/prometheus-exporter') }, [ _('Status → Prometheus exporter') ]), '.'
				]),
				E([], this.alerts(data, ifaces)),
				this.panel,
				node
			]);
		});
	},

	alerts(data, ifaces) {
		const out = [];

		if (!L.isObject(data) || !Array.isArray(data.collectors))
			out.push(alertBox('warning', [ _('The installed collectors could not be read.') ]));
		else if (Array.isArray(data.skipped) && data.skipped.length)
			out.push(alertBox('warning', [
				_('These collectors are installed but do not load:'),
				E('ul', {}, data.skipped.map((msg) => E('li', {}, [ String(msg) ])))
			]));

		if (!L.isObject(ifaces) || !Array.isArray(ifaces.interfaces))
			out.push(alertBox('warning', [
				_('The router\'s interfaces could not be read, so only every address and the saved interface are offered to listen on.'),
				' ', String(ifaces?.message ?? '')
			]));

		return out;
	},

	// An option of the main section, on the Exporter tab, which the object's validate may mark.
	option(s, type, name, title, description) {
		const o = s.taboption('exporter', type, name, title, description);

		this.mainOptions[name] = o;
		o.validate = (section_id, value) => {
			const mark = lookup(this.marks, name);
			return (mark && mark.value === value) ? mark.message : true;
		};

		return o;
	},

	// Every field writes its value, even at the default, so the saved section states every
	// setting; but for the TLS files, unset without TLS. A field left empty is refused.
	renderMain(s, interfaces) {
		let o = this.option(s, form.Flag, 'enabled', _('Enable'), _('Off, the service does not start.'));
		o.default = '1';
		o.rmempty = false;

		o = this.option(s, ListenSelect, 'listen_interface', _('Listen on'),
			_('The interface whose addresses serve the metrics, or every address. On loopback only programs on the router reach them.'));
		o.default = 'loopback';
		o.interfaces = interfaces;

		o = this.option(s, form.Value, 'listen_port', _('Port'));
		o.datatype = 'port';
		o.default = '9100';
		o.placeholder = '9100';
		o.rmempty = false;

		o = this.option(s, form.Value, 'http_keepalive', _('Keep-alive'),
			_('Seconds an idle connection stays open; 0 closes it after each reply.'));
		o.datatype = 'uinteger';
		o.default = '70';
		o.placeholder = '70';
		o.rmempty = false;

		o = this.option(s, form.Value, 'cert', _('TLS certificate'),
			_('With a key, serves HTTPS. Both files must exist, and uhttpd needs a TLS library.'));
		o.datatype = 'file';
		o.placeholder = '/etc/uhttpd.crt';

		o = this.option(s, form.Value, 'key', _('TLS key'));
		o.datatype = 'file';
		o.placeholder = '/etc/uhttpd.key';

		const user = this.option(s, form.Value, 'auth_user', _('Basic auth user'),
			_('With a password, a scrape logs in as this user. Over HTTPS only: it takes the TLS certificate and key. Empty for none.'));
		user.placeholder = _('none');

		o = this.option(s, PasswordValue, 'auth_password', _('Basic auth password'),
			_('Saved as a hash, never as typed, and never shown. Empty keeps the saved one.'));
		o.password = true;
		o.user = user;
		o.validate = (section_id, value) => {
			const mark = lookup(this.marks, 'auth_password');

			if (mark && mark.value === value)
				return mark.message;
			if (value != null && new TextEncoder().encode(value).length > PASSWORD_MAX)
				return _('At most %d bytes').format(PASSWORD_MAX);
			if (/[\x00-\x1f\x7f]/.test(value ?? ''))
				return _('No control characters');

			return true;
		};

		o = this.option(s, form.Flag, 'compress', _('Compress'),
			_('Sends a scrape gzip-compressed when the scraper asks for it, as Prometheus and vmagent do.'));
		o.default = '1';
		o.rmempty = false;

		o = this.option(s, form.Flag, 'omit_zero_values', _('Leave out zero values'),
			_('Leaves out counters that are 0, most of which never move on a router.'));
		o.default = '0';
		o.rmempty = false;

		o = this.option(s, form.Value, 'exec_timeout', _('Time for programs'),
			_('Seconds the programs a collector runs get in all in each scrape, 1 to 30; one still running then is killed, and its collector fails. A collector may have a default of its own, and its Edit dialog sets its own time.'));
		o.datatype = 'range(1,30)';
		o.default = '5';
		o.placeholder = '5';
		o.rmempty = false;

		o = this.option(s, form.Value, 'scrape_timeout', _('Time for a scrape'),
			_('Seconds a scrape has to answer when the scraper does not say, 1 to 60. Prometheus and vmagent say how long they wait; collectors left when that time is nearly spent are left out, so that the scrape answers in time.'));
		o.datatype = 'range(1,60)';
		o.default = '10';
		o.placeholder = '10';
		o.rmempty = false;

		o = this.option(s, form.Value, 'collector_budget', _('Time for a collector'),
			_('Seconds a collector may take in a scrape, 1 to 60. One that takes longer is quarantined: it is not run for a few scrapes, then tried again.'));
		o.datatype = 'range(1,60)';
		o.default = '5';
		o.placeholder = '5';
		o.rmempty = false;
	},

	// The form's values as the object's validate takes them: empty fields left out, as unset.
	// Basic auth's password is the saved hash, or a stand-in for one when a password is
	// typed; it is none without a user.
	candidate() {
		const main = {};

		for (const name in this.mainOptions) {
			const value = this.mainOptions[name].formvalue('main');
			if (value != null && value !== '')
				main[name] = String(value);
		}

		const saved = this.mainOptions.auth_password.saved('main');

		delete main.auth_password;
		if (main.auth_user != null && !blank(this.mainOptions.auth_password.formvalue('main')))
			main.auth_password = PENDING_HASH;
		else if (main.auth_user != null && !blank(saved))
			main.auth_password = saved;

		return { main: main, collectors: this.table.candidate() };
	},

	scheduleCheck(delay) {
		window.clearTimeout(this.checkTimer);
		this.checkTimer = window.setTimeout(() => this.check(), delay ?? CHECK_DELAY);
	},

	// Resolves to the object's answer, or to null when there is none; an answer to an
	// earlier check than the last is dropped.
	check() {
		const seq = ++this.checkSeq;
		const candidate = this.candidate();

		window.clearTimeout(this.checkTimer);

		return exporter.validate(candidate.main, candidate.collectors).then((res) => {
			if (seq !== this.checkSeq)
				return null;

			if (!L.isObject(res) || !L.isObject(res.errors)) {
				this.showProblem([ _('The settings could not be checked:'), ' ', String(res?.message ?? res?.error ?? '') ]);
				return null;
			}

			this.mark(candidate, res.errors);
			dom.content(this.panel, []);
			return res;
		}, (err) => {
			if (seq === this.checkSeq)
				this.showProblem([ _('The settings could not be checked:'), ' ', String(err?.message ?? err) ]);
			return null;
		});
	},

	mark(candidate, errors) {
		this.marks = {};

		for (const name in (errors.main ?? {}))
			this.marks[name] = {
				// The password's field holds what is typed, not what was checked.
				value: (name === 'auth_password') ? (this.mainOptions.auth_password.formvalue('main') ?? '') : (candidate.main[name] ?? ''),
				message: String(errors.main[name])
			};

		for (const name in this.mainOptions)
			this.mainOptions[name].triggerValidation('main');
	},

	showProblem(children) {
		dom.content(this.panel, alertBox('error', children));
	},

	// What the object found, in a list above the form.
	showRefused(errors) {
		const items = [];
		const titles = { enabled: _('Enable'), listen_interface: _('Listen on'), listen_port: _('Port'),
			http_keepalive: _('Keep-alive'), cert: _('TLS certificate'), key: _('TLS key'), auth_user: _('Basic auth user'),
			auth_password: _('Basic auth password'), compress: _('Compress'), omit_zero_values: _('Leave out zero values'),
			exec_timeout: _('Time for programs'), scrape_timeout: _('Time for a scrape'), collector_budget: _('Time for a collector') };

		for (const name in (errors.main ?? {}))
			items.push(E('li', {}, [ lookup(titles, name) ?? name, ': ', String(errors.main[name]) ]));

		for (const id in (errors.collectors ?? {}))
			for (const name in errors.collectors[id])
				items.push(E('li', {}, [ E('code', {}, [ id ]), ' ', E('code', {}, [ name ]), ': ', String(errors.collectors[id][name]) ]));

		dom.content(this.panel, alertBox('error', [
			E('p', {}, [ _('Nothing was saved: the exporter would refuse these values.') ]),
			E('ul', {}, items)
		]));
	},

	// Saves only what the object passes.
	checked() {
		return this.check().then((res) => {
			if (res == null)
				return false;
			if (!res.ok)
				this.showRefused(res.errors);
			return res.ok === true;
		});
	},

	handleSave(ev) {
		return this.checked().then((ok) => ok ? this.super('handleSave', [ ev ]) : null);
	},

	handleSaveApply(ev, mode) {
		return this.checked().then((ok) => ok
			? this.super('handleSave', [ ev ]).then(() => ui.changes.apply(mode == '0'))
			: null);
	},

	handleReset(ev) {
		dom.content(this.panel, []);
		this.marks = {};
		return this.super('handleReset', [ ev ]);
	}
});
