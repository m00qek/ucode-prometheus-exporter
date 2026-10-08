'use strict';
'require baseclass';
'require form';
'require uci';
'require ui';
'require dom';
'require prometheus-exporter as exporter';

// The settings page's own widgets (view/prometheus-exporter/settings.js): the
// listen interface's picker, basic auth's password, and the Collectors tab's table,
// a row per installed collector with its switch, and its Edit dialog.
//
// Collector names and help, package names, interfaces and paths come from the router: they
// reach E() only inside arrays, and never a form title or description, which LuCI renders
// as markup.

const CONFIG = exporter.CONFIG;
const lookup = exporter.lookup;
const fill = exporter.fill;

// How long typing pauses before the values are checked, in ms.
const CHECK_DELAY = 300;

// What every collector package's name starts with; the Package column shows the rest.
const PACKAGE_PREFIX = 'ucode-prometheus-exporter-';

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

// A line of a list of what was refused or skipped. Not an <li>: a theme may colour list
// items its own way, which an alert's colours do not reach (material's grey on red).
function line(children) {
	return E('div', { 'class': 'exporter-line' }, children);
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

		const failed = (why) => new Error(_('The password could not be hashed:') + ' ' + why);

		return exporter.hashPassword(typed).then((res) => {
			if (!L.isObject(res) || typeof(res.hash) !== 'string')
				throw failed(exporter.describeError(res));

			uci.set(CONFIG, section_id, 'auth_password', res.hash);
		}, (err) => {
			throw failed(exporter.describeError(err));
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
		this.failed = false;
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
		const title = (c) => String(c.title || c.name || '');
		const sorted = this.collectors.slice().sort((a, b) => title(a).localeCompare(title(b)));

		this.rows = sorted.map((c, i) => this.renderRow(c, i, headers));
		this.count = E('p', { 'class': 'exporter-count' }, []);
		this.updateCount();

		const empty = this.failed ? _('The collectors could not be read.') : _('No collector is installed.');
		const body = this.rows.length ? this.rows.map((row) => row.node) : [
			E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': String(headers.length) }, [ E('em', {}, [ empty ]) ])
			])
		];

		const table = E('table', { 'class': 'table cbi-section-table', 'id': this.cbid(section_id) }, [
			E('tr', { 'class': 'tr table-titles' }, headers.map((h, i) =>
				E('th', { 'class': (i === headers.length - 1) ? 'th cbi-section-actions' : 'th' }, [ h ])))
		].concat(body));

		table.addEventListener('widget-change', () => this.updateCount());
		table.addEventListener('change', () => this.updateCount());

		return E([], [ this.rows.length ? this.count : '', table ]);
	},

	// How many collectors are switched on, as the page has them.
	updateCount() {
		const on = this.rows.filter((row) => row.enabled.getValue() === '1').length;
		dom.content(this.count, [ _('%d of %d collectors enabled').format(on, this.rows.length) ]);
	},

	renderRow(c, i, headers) {
		const readonly = this.map.readonly;
		const row = { c: c, note: E('div', {}, this.errorNote(c.error)), node: null };

		// An invalid value shows as on, as the exporter would take it once it is fixed.
		row.enabled = new ui.Checkbox(switchState(this.sectionOf(c.id)?.enabled) === 'off' ? '0' : '1',
			{ id: `cbid.${CONFIG}.${c.id}.enabled`, disabled: readonly });

		const toggle = row.enabled.render();
		toggle.querySelector('input').setAttribute('aria-label', fill(_('Enable the %s collector'), c.name).join(''));

		// A read-only login opens the dialog too: its fields and Save are disabled there.
		row.edit = (c.options ?? []).length ? E('button', {
			'class': 'btn cbi-button cbi-button-edit',
			'title': fill(_('Edit the options of %s'), c.name).join(''),
			'click': ui.createHandlerFn(this, 'openEditor', row)
		}, [ _('Edit') ]) : null;

		row.node = E('tr', { 'class': 'tr cbi-section-table-row cbi-rowstyle-' + (1 + i % 2), 'data-collector': c.id }, [
			E('td', { 'class': 'td', 'data-title': headers[0] }, [
				...exporter.nameOf(c), E('br'), E('small', {}, [ String(c.help ?? '') ]), row.note
			]),
			E('td', { 'class': 'td', 'data-title': headers[1] }, [ this.packageOf(c) ]),
			E('td', { 'class': 'td', 'data-title': headers[2] }, [ toggle ]),
			E('td', { 'class': 'td cbi-section-actions' }, [ row.edit ?? '' ])
		]);

		return row;
	},

	// The base package, the removable package that installed it by the rest of its name
	// (wifi for ucode-prometheus-exporter-wifi), or none.
	packageOf(c) {
		if (c.base === true)
			return E('span', {}, [ _('Base') ]);

		if (!c.package)
			return E('em', {}, [ _('None') ]);

		const name = String(c.package);
		const short = name.startsWith(PACKAGE_PREFIX) ? name.substring(PACKAGE_PREFIX.length) : name;

		return E('code', { 'title': name }, [ short ]);
	},

	errorNote(error) {
		return error ? [ E('small', { 'class': 'exporter-error', 'style': 'color:var(--error-color-high,#c43c35)' },
			fill(_('The saved settings are not valid: %s'), String(error))) ] : [];
	},

	// What the collector reads, and what its jail gives it, as rows of the dialog.
	reads(c) {
		const rows = [];
		const mounts = c.jail?.mounts ?? [];
		const problems = c.jail?.problems ?? [];
		const info = (name, title, children) => E('div', { 'class': 'cbi-value', 'data-info': name }, [
			E('label', { 'class': 'cbi-value-title' }, [ title ]),
			E('div', { 'class': 'cbi-value-field' }, children)
		]);

		if ((c.configs ?? []).length)
			rows.push(info('reads', _('Reads'), codes(c.configs.map((name) => `/etc/config/${name}`))));

		if ((c.commands ?? []).length)
			rows.push(info('runs', _('Runs'), codes(c.commands)));

		rows.push(info('jail', _('Jail mounts'), mounts.length ? codes(mounts)
			: [ _('Only what every collector gets: procfs, sysfs, ubus and the log.') ]));

		if (problems.length)
			rows.push(info('problems', _('Jail problems'), problems.map((problem) => E('div', {}, [ String(problem) ]))));

		return rows;
	},

	// The dialog of a collector's options: a field per option, by its type, labelled by its
	// title, with its help, which the object's validate checks as it is typed; and what the
	// collector reads.
	openEditor(row) {
		const c = row.c;
		const section = this.sectionOf(c.id);
		const editor = { row: row, fields: [], marks: {}, seq: 0, timer: null, problem: E('div', {}, []) };
		const fields = (c.options ?? []).map((o) => this.renderField(editor, o, section));

		editor.node = E('div', { 'class': 'exporter-editor', 'data-collector': c.id }, [
			E('p', {}, [ String(c.help ?? '') ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-node' }, fields),
				E('div', { 'class': 'cbi-section-node exporter-reads' }, this.reads(c))
			]),
			editor.problem
		]);

		// As LuCI's own dialogs: Escape presses the first button of the row, Dismiss.
		const buttons = E('div', { 'class': 'button-row' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'dismissEditor', editor) }, [ _('Dismiss') ]),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-positive important',
				'disabled': this.map.readonly ? '' : null,
				'click': ui.createHandlerFn(this, 'saveEditor', editor)
			}, [ _('Save') ])
		]);

		editor.node.addEventListener('input', () => this.scheduleEditorCheck(editor));
		editor.node.addEventListener('widget-change', () => this.scheduleEditorCheck(editor));

		this.editor = editor;
		ui.showModal(exporter.nameOf(c), [ editor.node, buttons ], 'cbi-modal');

		// The first field takes the focus; a read-only login's are disabled, so Dismiss does.
		const first = editor.node.querySelector('input:not([type="hidden"]):not([disabled]), select:not([disabled])');
		(first ?? buttons.querySelector('button')).focus();

		this.checkEditor(editor);
	},

	renderField(editor, o, section) {
		const c = editor.row.c;
		const raw = (section != null) ? section[o.name] : null;
		const id = `cbid.${CONFIG}.${c.id}.${o.name}`;
		const title = exporter.optionTitle(c, o.name);
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
			input.setAttribute('aria-label', fill(_('%s option of the %s collector'), title, c.name).join(''));

		editor.fields.push({ option: o, widget: widget });

		return E('div', { 'class': 'cbi-value', 'data-option': o.name }, [
			E('label', { 'class': 'cbi-value-title', 'for': input?.id ?? null }, [ title ]),
			E('div', { 'class': 'cbi-value-field' }, [ node ].concat(o.help
				? [ E('div', { 'class': 'cbi-value-description' }, [ String(o.help) ]) ] : []))
		]);
	},

	// What an empty field stands for: the option's default. The timeout of a collector
	// without a default of its own follows exec_timeout, as the Limits tab has it now.
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
				this.showEditorProblem(editor, [ _('The options could not be checked:'), ' ', exporter.describeError(res) ]);
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
				this.showEditorProblem(editor, [ _('The options could not be checked:'), ' ', exporter.describeError(err) ]);
			return null;
		});
	},

	showEditorProblem(editor, children) {
		dom.content(editor.problem, alertBox('error', children));
	},

	// Hides the dialog, and gives the focus back to the row's Edit: on Dismiss, on Escape
	// (which presses Dismiss), and once Save has staged the values.
	dismissEditor(editor) {
		editor.seq++;
		window.clearTimeout(editor.timer);
		this.editor = null;
		ui.hideModal();
		editor.row.edit?.focus();
	},

	// Stages the dialog's values in uci when the exporter would take them all; the page's
	// Save & Apply applies them.
	saveEditor(editor) {
		const c = editor.row.c;

		if (this.map.readonly)
			return Promise.resolve(null);

		return this.checkEditor(editor).then((res) => {
			if (res == null)
				return null;

			const refused = [];

			for (const f of editor.fields) {
				const name = f.option.name;
				const message = lookup(res.errors, name) ?? (f.widget.isValid() ? null : f.widget.getValidationError());

				if (message != null)
					refused.push(line([ exporter.optionTitle(c, name), ': ', String(message) ]));
			}

			if (refused.length) {
				this.showEditorProblem(editor, [
					E('p', {}, [ _('Nothing was staged: the exporter would refuse these values.') ]),
					E('div', {}, refused)
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
				this.dismissEditor(editor);
				return this.refreshNote(editor.row);
			}, (err) => {
				this.showEditorProblem(editor, [ _('The options could not be staged:'), ' ', exporter.describeError(err) ]);
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

return baseclass.extend({
	CHECK_DELAY: CHECK_DELAY,
	alertBox: alertBox,
	line: line,
	blank: blank,

	ListenSelect: ListenSelect,
	PasswordValue: PasswordValue,
	CollectorTable: CollectorTable
});
