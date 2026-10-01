'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require network';
'require tools.widgets as widgets';
'require prometheus-node-exporter-ucode as exporter';

// Services → Prometheus exporter: /etc/config/prometheus-node-exporter-ucode as a form.
// The Exporter section is the main section. The Collectors section has a row per installed
// collector, as the plugin's `collectors` lists them, with its switch and its options. A
// collector's `config collector '<module>'` section holds only what differs from the
// defaults: it is added when a value first differs, and removed once all are back.
//
// The plugin's `validate` checks the form's values as the exporter reads them, while they
// are typed and again before Save, which saves nothing the exporter would refuse.
//
// Collector names and help, package names and paths come from the router: they reach E()
// only inside arrays, and never a form title or description, which LuCI renders as markup.

const CONFIG = exporter.CONFIG;
const lookup = exporter.lookup;
const fill = exporter.fill;

// How long typing pauses before the form is checked, in ms.
const CHECK_DELAY = 300;

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

// The listen interface: LuCI's network picker, which also offers every address (*), as
// the init script does, and keeps a value it does not list, such as an interface of a
// network this login may not read.
const ListenSelect = widgets.NetworkSelect.extend({
	__name__: 'CBI.PrometheusExporterListen',

	// NetworkSelect's own, without its this.super(), which in a subclass of it would call
	// this load again, and again.
	load(section_id) {
		return network.getNetworks().then((networks) => {
			this.networks = networks;
			return form.ListValue.prototype.load.call(this, section_id);
		});
	},

	renderWidget(section_id, option_index, cfgvalue) {
		const value = (cfgvalue != null && cfgvalue !== '') ? cfgvalue : this.default;
		const choices = { '*': E('em', {}, [ _('Every address') ]) };

		for (const network of this.networks)
			choices[network.getName()] = this.renderIfaceBadge(network);

		if (!lookup(choices, value))
			choices[value] = E('span', { 'class': 'ifacebadge' }, [ value ]);

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

// A row per installed collector: its switch, its options by type (a checkbox for a
// boolean, a text field with its datatype for an integer or a string) and where it comes
// from. Saving writes only the rows that changed, and each as the smallest section that
// holds its values.
const CollectorTable = form.Value.extend({
	__name__: 'CBI.PrometheusExporterCollectors',

	__init__(...args) {
		this.super('__init__', args);
		this.collectors = [];
		this.rows = [];
		this.marks = {};
	},

	// The collector's own section, as LuCI has it with unsaved changes; null when there is
	// none, or the name is taken by a section of another type, which the exporter ignores.
	sectionOf(id) {
		const s = uci.get(CONFIG, id);
		return (L.isObject(s) && s['.type'] === 'collector') ? s : null;
	},

	cfgvalue(section_id) {
		return null;
	},

	renderWidget(section_id, option_index, cfgvalue) {
		const headers = [ _('Collector'), _('Enabled'), _('Options') ];

		this.rows = this.collectors.map((c, i) => this.renderRow(c, i, headers));

		const body = this.rows.length ? this.rows.map((row) => row.node) : [
			E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': String(headers.length) }, [ E('em', {}, [ _('No collector is installed.') ]) ])
			])
		];

		return E('table', { 'class': 'table', 'id': this.cbid(section_id) }, [
			E('tr', { 'class': 'tr table-titles' }, headers.map((h) => E('th', { 'class': 'th' }, [ h ])))
		].concat(body));
	},

	renderRow(c, i, headers) {
		const section = this.sectionOf(c.id);
		const readonly = this.map.readonly;
		const cbid = (name) => `cbid.${CONFIG}.${c.id}.${name}`;
		const row = { c: c, fields: [], node: null };
		const saved = section?.enabled;

		// A value that is not a boolean counts as enabled, as the exporter takes it.
		row.enabled = new ui.Checkbox((saved != null && exporter.isFalse(saved)) ? '0' : '1', { id: cbid('enabled'), disabled: readonly });
		const enabledNode = row.enabled.render();
		enabledNode.querySelector('input').setAttribute('aria-label', fill(_('Enable %s'), c.name).join(''));

		const options = (c.options ?? []).map((o) => this.renderOption(c, o, section, cbid(o.name), row));

		row.initial = this.values(row);
		row.node = E('tr', { 'class': 'tr cbi-rowstyle-' + (1 + i % 2), 'data-collector': c.id }, [
			E('td', { 'class': 'td', 'data-title': headers[0] }, this.describe(c)),
			E('td', { 'class': 'td', 'data-title': headers[1] }, [ enabledNode ]),
			E('td', { 'class': 'td', 'data-title': headers[2] }, options.length ? options : [ E('em', {}, [ _('None') ]) ])
		]);

		return row;
	},

	// The title, the help, the package and what it reads; and what is wrong with the
	// saved section, if anything.
	describe(c) {
		const notes = [];

		if (c.base === true)
			notes.push([ _('In the base package') ]);
		else if (c.package)
			notes.push(fill(_('Package %s, which can be removed'), E('code', {}, [ c.package ])));
		else
			notes.push([ _('Not installed by a package') ]);

		if ((c.configs ?? []).length)
			notes.push(fill(_('Reads %s'), joined(c.configs.map((name) => E('code', {}, [ `/etc/config/${name}` ])), ', ')));

		if ((c.commands ?? []).length)
			notes.push(fill(_('Runs %s'), joined(c.commands.map((name) => E('code', {}, [ name ])), ', ')));

		const out = [ ...exporter.nameOf(c), E('br'), E('small', {}, [ c.help ?? '' ]) ];

		for (const note of notes)
			out.push(E('br'), E('small', { 'class': 'exporter-note' }, note));

		if (c.error)
			out.push(E('br'), E('small', { 'class': 'exporter-error', 'style': 'color:var(--error-color-high,#c43c35)' },
				fill(_('The saved settings are not valid: %s'), c.error)));

		return out;
	},

	renderOption(c, o, section, id, row) {
		const raw = (section != null) ? section[o.name] : null;
		const help = o.help ? [ E('br'), E('small', {}, [ o.help ]) ] : [];
		let widget;

		if (o.type === 'bool') {
			const checked = (raw == null) ? o.default === true : exporter.isTrue(raw);
			widget = new ui.Checkbox(checked ? '1' : '0', { id: id, disabled: this.map.readonly });
		}
		else {
			widget = new ui.Textfield((typeof(raw) === 'string') ? raw : '', {
				id: id,
				optional: true,
				placeholder: String(o.default ?? ''),
				datatype: exporter.datatypeOf(o),
				disabled: this.map.readonly,
				validate: (value) => this.checkMark(c.id, o.name, value)
			});
		}

		const node = widget.render();
		const input = node.querySelector('input:not([type="hidden"])');

		if (input)
			input.setAttribute('aria-label', fill(_('%s of %s'), o.name, c.name).join(''));

		row.fields.push({ option: o, widget: widget });

		return E('div', { 'class': 'exporter-option', 'data-option': o.name }, [
			E('label', { 'for': input?.id ?? null }, [ E('code', {}, [ o.name ]) ]),
			node
		].concat(help));
	},

	// What a row's fields hold: '1' or '0' for a switch, the text of a text field.
	values(row) {
		const out = { enabled: row.enabled.getValue() === '1' ? '1' : '0' };

		for (const f of row.fields)
			out[f.option.name] = (f.option.type === 'bool') ? (f.widget.getValue() === '1' ? '1' : '0') : f.widget.getValue();

		return out;
	},

	// The form's values for the plugin's validate: empty fields left out, as unset.
	candidate() {
		const out = {};

		for (const row of this.rows) {
			const values = this.values(row);

			for (const name in values)
				if (values[name] === '')
					delete values[name];

			out[row.c.id] = values;
		}

		return out;
	},

	// A failed check marks its field until the field's value changes.
	setMarks(errors, candidate) {
		this.marks = {};

		for (const id in (errors ?? {}))
			for (const name in errors[id])
				this.marks[`${id}.${name}`] = { value: candidate[id]?.[name] ?? '', message: String(errors[id][name]) };

		this.triggerValidation();
	},

	checkMark(id, name, value) {
		const mark = lookup(this.marks, `${id}.${name}`);
		return (mark && mark.value === value) ? mark.message : true;
	},

	textFields() {
		return this.rows.flatMap((row) => row.fields.filter((f) => f.option.type !== 'bool').map((f) => ({ row: row, field: f })));
	},

	formvalue(section_id) {
		return this.candidate();
	},

	isValid(section_id) {
		return this.textFields().every((x) => x.field.widget.isValid());
	},

	getValidationError(section_id) {
		for (const x of this.textFields())
			if (!x.field.widget.isValid())
				return `${x.row.c.name} ${x.field.option.name}: ${x.field.widget.getValidationError()}`;

		return '';
	},

	triggerValidation(section_id) {
		let changed = false;

		for (const x of this.textFields())
			changed = x.field.widget.triggerValidation() || changed;

		return changed;
	},

	parse(section_id) {
		if (!this.isValid(section_id))
			return Promise.reject(new TypeError(`${_('A collector option is not valid:')} ${this.getValidationError(section_id)}`));

		for (const row of this.rows) {
			const now = this.values(row);

			if (Object.keys(now).some((name) => now[name] !== row.initial[name]))
				this.writeCollector(row.c, now);
		}

		return Promise.resolve();
	},

	// What a value comes to in the section: null when it is the default, and so unset.
	minimal(o, value) {
		switch (o.type) {
		case 'bool':
			return ((value === '1') === (o.default === true)) ? null : value;
		case 'int':
			return (value === '' || (/^-?[0-9]+$/.test(value) && +value === o.default)) ? null : value;
		default:
			return (value === '' || value === o.default) ? null : value;
		}
	},

	writeCollector(c, now) {
		const id = c.id;
		const want = { enabled: (now.enabled === '1') ? null : '0' };

		for (const o of (c.options ?? []))
			want[o.name] = this.minimal(o, now[o.name]);

		const named = uci.get(CONFIG, id);

		// The name is another type's section, which the exporter ignores: not ours to change.
		if (L.isObject(named) && named['.type'] !== 'collector')
			return;

		if (!named) {
			if (Object.values(want).every((v) => v == null))
				return;
			uci.add(CONFIG, 'collector', id);
		}

		for (const name in want) {
			if (want[name] == null) {
				if (uci.get(CONFIG, id, name) != null)
					uci.unset(CONFIG, id, name);
			}
			else if (uci.get(CONFIG, id, name) !== want[name]) {
				uci.set(CONFIG, id, name, want[name]);
			}
		}

		// Options nobody declared keep the section; otherwise one with nothing left goes.
		const left = Object.keys(uci.get(CONFIG, id) ?? {}).filter((k) => k.charAt(0) !== '.');
		if (!left.length)
			uci.remove(CONFIG, id);
	}
});

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(exporter.collectors(), null),
			uci.load(CONFIG)
		]);
	},

	render([ data ]) {
		// The form edits the main section: a config without one gets it, as the exporter
		// reads a missing one, every option at its default.
		if (uci.get(CONFIG, 'main') == null)
			uci.add(CONFIG, CONFIG, 'main');

		const m = new form.Map(CONFIG);

		this.map = m;
		this.mainOptions = {};
		this.marks = {};
		this.checkSeq = 0;
		this.checkTimer = null;

		this.renderMain(m.section(form.NamedSection, 'main', CONFIG, _('Exporter')));

		const s = m.section(form.NamedSection, 'main', CONFIG, _('Collectors'),
			_('A collector that is not enabled is not served. Its section in the configuration holds only what differs from the defaults.'));
		this.table = s.option(CollectorTable, '_collectors', '');
		this.table.collectors = Array.isArray(data?.collectors) ? data.collectors : [];

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
					E('a', { 'href': L.url('admin/status/prometheus-node-exporter-ucode') }, [ _('Status → Prometheus exporter') ]), '.'
				]),
				E([], this.alerts(data)),
				this.panel,
				node
			]);
		});
	},

	alerts(data) {
		if (!L.isObject(data) || !Array.isArray(data.collectors))
			return [ alertBox('warning', [ _('The installed collectors could not be read.') ]) ];

		if (Array.isArray(data.skipped) && data.skipped.length)
			return [ alertBox('warning', [
				_('These collectors are installed but do not load:'),
				E('ul', {}, data.skipped.map((msg) => E('li', {}, [ String(msg) ])))
			]) ];

		return [];
	},

	// An option of the main section, which the plugin's validate may mark.
	option(s, type, name, title, description) {
		const o = s.option(type, name, title, description);

		this.mainOptions[name] = o;
		o.validate = (section_id, value) => {
			const mark = lookup(this.marks, name);
			return (mark && mark.value === value) ? mark.message : true;
		};

		return o;
	},

	renderMain(s) {
		let o = this.option(s, form.Flag, 'enabled', _('Enable'), _('Off, the service does not start.'));
		// The init script takes an unset option as enabled: switched on, it is removed.
		o.default = '1';

		o = this.option(s, ListenSelect, 'listen_interface', _('Listen on'),
			_('The interface whose addresses serve the metrics, or every address. On loopback only programs on the router reach them.'));
		o.default = 'loopback';
		o.loopback = true;
		o.nocreate = true;

		o = this.option(s, form.Value, 'listen_port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '9101';

		o = this.option(s, form.Value, 'http_keepalive', _('Keep-alive'),
			_('Seconds an idle connection stays open; 0 closes it after each reply.'));
		o.datatype = 'uinteger';
		o.placeholder = '70';

		o = this.option(s, form.Value, 'cert', _('TLS certificate'),
			_('With a key, serves HTTPS. Both files must exist, and uhttpd needs a TLS library.'));
		o.datatype = 'file';
		o.placeholder = '/etc/uhttpd.crt';

		o = this.option(s, form.Value, 'key', _('TLS key'));
		o.datatype = 'file';
		o.placeholder = '/etc/uhttpd.key';

		o = this.option(s, form.Flag, 'omit_zero_values', _('Leave out zero values'),
			_('Leaves out counters that are 0, most of which never move on a router.'));
		o.default = '0';
	},

	// The form's values as the plugin's validate takes them: empty fields left out, as unset.
	candidate() {
		const main = {};

		for (const name in this.mainOptions) {
			const value = this.mainOptions[name].formvalue('main');
			if (value != null && value !== '')
				main[name] = String(value);
		}

		return { main: main, collectors: this.table.candidate() };
	},

	scheduleCheck(delay) {
		window.clearTimeout(this.checkTimer);
		this.checkTimer = window.setTimeout(() => this.check(), delay ?? CHECK_DELAY);
	},

	// Resolves to the plugin's answer, or to null when there is none; an answer to an
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
			this.marks[name] = { value: candidate.main[name] ?? '', message: String(errors.main[name]) };

		for (const name in this.mainOptions)
			this.mainOptions[name].triggerValidation('main');

		this.table.setMarks(errors.collectors, candidate.collectors);
	},

	showProblem(children) {
		dom.content(this.panel, alertBox('error', children));
	},

	// What the plugin found, in a list above the form.
	showRefused(errors) {
		const items = [];
		const titles = { enabled: _('Enable'), listen_interface: _('Listen on'), listen_port: _('Port'),
			http_keepalive: _('Keep-alive'), cert: _('TLS certificate'), key: _('TLS key'), omit_zero_values: _('Leave out zero values') };

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

	// Saves only what the plugin passes.
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
