'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require prometheus-exporter as exporter';

// Services → Prometheus exporter: /etc/config/prometheus-exporter as a form, in two tabs.
// Exporter has the main section's options. Collectors has a row per installed collector, as
// the ubus object's `collectors` lists them, by title: its title and help, its package, its
// switch, and, when it has options, an Edit button. Edit opens a dialog with a field per
// option (the collector's own, and the core's timeout when it runs programs), whose Save
// stages them in uci, as LuCI's own dialogs do; the page's Save & Apply applies them with
// the rest, and Dismiss drops them. A read-only login opens the dialog too, its fields and
// Save disabled, as LuCI's GridSection has it.
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
// before it stages them. Nothing the exporter would refuse is saved: a Save it refuses says
// why in a dialog, as LuCI's own Save error does, and above the form until it is fixed.
// Without the object (rpcd reloading, the package upgraded), the page is read-only.
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

	// The dialog of a collector's options: a field per option, by its type, with its help,
	// which the object's validate checks as it is typed; and what the collector reads.
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
			input.setAttribute('aria-label', fill(_('%s option of the %s collector'), o.name, c.name).join(''));

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
					refused.push(line([ E('code', {}, [ name ]), ': ', String(message) ]));
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

return view.extend({
	// A call that fails answers { failure }, which alerts() describes.
	load() {
		const failure = (err) => ({ failure: err });

		return Promise.all([
			exporter.collectors().catch(failure),
			exporter.interfaces().catch(failure),
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
		this.problem = null;

		// Without the object nothing can be checked, so nothing is saved: the page is
		// read-only, as for a login that may not write the config.
		this.unavailable = exporter.isUnavailable(data?.failure);
		if (this.unavailable)
			m.readonly = true;

		s.tab('exporter', _('Exporter'));
		s.tab('collectors', _('Collectors'),
			_('Untick a collector to stop serving its metrics; Edit changes its options; Save & Apply applies them.'));

		this.renderMain(s, (L.isObject(ifaces) && Array.isArray(ifaces.interfaces)) ? ifaces.interfaces : []);

		this.table = s.taboption('collectors', CollectorTable, '_collectors', '');
		this.table.collectors = Array.isArray(data?.collectors) ? data.collectors : [];
		this.table.failed = !Array.isArray(data?.collectors);
		this.table.execTimeout = () => this.mainOptions.exec_timeout?.formvalue('main');

		this.panel = E('div', {}, []);

		return m.render().then((node) => {
			if (!this.unavailable) {
				node.addEventListener('widget-change', () => this.scheduleCheck());
				node.addEventListener('input', () => this.scheduleCheck());
				this.scheduleCheck(0);
			}

			return E([], [
				E('h2', { 'name': 'content' }, [ _('Prometheus exporter') ]),
				E('div', { 'class': 'cbi-map-descr' }, [
					_('Node metrics for Prometheus, served at /metrics.'), ' ',
					...fill(_('Whether it runs, and how each collector did, is under %s.'),
						E('a', { 'href': L.url('admin/status/prometheus-exporter') }, [ _('Status → Prometheus exporter') ]))
				]),
				E([], this.alerts(data, ifaces)),
				this.panel,
				node
			]);
		});
	},

	alerts(data, ifaces) {
		const out = [];

		// The object missing is one alert: the interfaces are not there for the same reason.
		if (this.unavailable)
			return [ alertBox('warning', [
				exporter.describeError(data.failure), ' ', _('Until then the settings are read-only.')
			]) ];

		if (!L.isObject(data) || !Array.isArray(data.collectors))
			out.push(alertBox('warning', [
				_('The installed collectors could not be read:'), ' ', exporter.describeError(data?.failure ?? data)
			]));
		else if (Array.isArray(data.skipped) && data.skipped.length)
			out.push(alertBox('warning', [
				_('These collectors are installed but do not load:'),
				E('div', {}, data.skipped.map((msg) => line([ String(msg) ])))
			]));

		if (!L.isObject(ifaces) || !Array.isArray(ifaces.interfaces))
			out.push(alertBox('warning', [
				_('The router\'s interfaces could not be read, so only every address and the saved interface are offered to listen on.'),
				' ', exporter.describeError(ifaces?.failure ?? ifaces)
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
		let o = this.option(s, form.Flag, 'enabled', _('Enable'), _('Runs the exporter.'));
		o.default = '1';
		o.rmempty = false;

		o = this.option(s, ListenSelect, 'listen_interface', _('Listen on'),
			_('The interface whose addresses serve the metrics, or every address. On loopback, only programs on the router can scrape it.'));
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
			_('With a key, serves HTTPS; empty, plain HTTP. Both files must exist, and uhttpd needs a TLS library. LuCI\'s own are /etc/uhttpd.crt and /etc/uhttpd.key.'));
		o.datatype = 'file';

		o = this.option(s, form.Value, 'key', _('TLS key'), _('The private key of the certificate.'));
		o.datatype = 'file';

		const user = this.option(s, form.Value, 'auth_user', _('Basic auth user'),
			_('Basic auth needs HTTPS: set the TLS certificate and key first. With a password, a scrape logs in as this user. Empty for none.'));
		user.placeholder = _('None');

		o = this.option(s, PasswordValue, 'auth_password', _('Basic auth password'),
			_('Saved as a hash; the password itself is never stored. Empty keeps the saved one.'));
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
			_('Gzip-compresses a scrape when the scraper asks for it, as Prometheus and vmagent do.'));
		o.default = '1';
		o.rmempty = false;

		o = this.option(s, form.Flag, 'omit_zero_values', _('Leave out zero values'),
			_('Leaves out counters that are 0, most of which never move on a router.'));
		o.default = '0';
		o.rmempty = false;

		o = this.option(s, form.Value, 'exec_timeout', _('Program timeout'),
			_('Seconds, 1 to 30, that the programs a collector runs get in each scrape; one still running then is stopped, and its collector fails. A collector\'s Edit can set its own.'));
		o.datatype = 'range(1,30)';
		o.default = '5';
		o.placeholder = '5';
		o.rmempty = false;

		o = this.option(s, form.Value, 'scrape_timeout', _('Scrape timeout'),
			_('Seconds, 1 to 60, a scrape has to answer when the scraper does not say; Prometheus and vmagent do. Collectors left when the time is nearly spent are skipped, so the scrape still answers.'));
		o.datatype = 'range(1,60)';
		o.default = '10';
		o.placeholder = '10';
		o.rmempty = false;

		o = this.option(s, form.Value, 'collector_budget', _('Collector budget'),
			_('Seconds, 1 to 60, a collector may take in a scrape. One that takes longer is quarantined: skipped for a few scrapes, then tried again.'));
		o.datatype = 'range(1,60)';
		o.default = '5';
		o.placeholder = '5';
		o.rmempty = false;

		o = this.option(s, form.Value, 'max_samples', _('Sample limit'),
			_('Samples, 1 to 100000, a collector may write in a scrape. One that writes more fails, and none of its samples are served.'));
		o.datatype = 'range(1,100000)';
		o.default = '20000';
		o.placeholder = '20000';
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
				this.showProblem(exporter.describeError(res));
				return null;
			}

			this.mark(candidate, res.errors);
			this.problem = null;
			dom.content(this.panel, []);
			return res;
		}, (err) => {
			if (seq === this.checkSeq)
				this.showProblem(exporter.describeError(err));
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

	// Why the settings could not be checked, above the form; a Save shows it in a dialog.
	showProblem(why) {
		this.problem = [ _('The settings could not be checked:'), ' ', why ];
		dom.content(this.panel, alertBox('error', this.problem));
	},

	// What the object found, in a list above the form, which stays until it is fixed, and
	// in a dialog, which the user sees wherever the page is scrolled.
	showRefused(errors) {
		const items = () => {
			const out = [];

			for (const name in (errors.main ?? {}))
				out.push(line([ lookup(this.mainOptions, name)?.title ?? name, ': ', String(errors.main[name]) ]));

			for (const id in (errors.collectors ?? {}))
				for (const name in errors.collectors[id])
					out.push(line([ E('code', {}, [ id ]), ' ', E('code', {}, [ name ]), ': ', String(errors.collectors[id][name]) ]));

			return out;
		};
		const refused = () => [
			E('p', {}, [ _('Nothing was saved: the exporter would refuse these values.') ]),
			E('div', {}, items())
		];

		dom.content(this.panel, alertBox('error', refused()));
		this.saveError(refused());
	},

	// LuCI's own Save error dialog, as form.Map's save() shows it; Dismiss, or Escape, gives
	// the focus back to what had it, the button that saved.
	saveError(children) {
		const from = document.activeElement;
		const dismiss = () => {
			ui.hideModal();
			if (from && from !== document.body && typeof(from.focus) === 'function')
				from.focus();
		};

		ui.showModal(_('Save error'), [
			...children,
			E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn cbi-button', 'click': dismiss }, [ _('Dismiss') ]) ])
		]);
	},

	// Saves only what the object passes.
	checked() {
		if (this.unavailable)
			return Promise.resolve(false);

		return this.check().then((res) => {
			if (res == null) {
				this.saveError([ E('p', {}, [ _('Nothing was saved.'), ' ', ...(this.problem ?? []) ]) ]);
				return false;
			}
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
