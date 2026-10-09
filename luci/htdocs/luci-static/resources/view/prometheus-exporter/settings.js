'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require prometheus-exporter as exporter';
'require prometheus-exporter.widgets as widgets';

// Services → Prometheus exporter: /etc/config/prometheus-exporter as a form, in four tabs.
// General, HTTPS & login and Limits have the main section's options. Collectors has a row
// per installed collector, as the ubus object's `collectors` lists them, by title: its
// title and help, its package, its switch, and, when it has options, an Edit button. Edit
// opens a dialog with a field per option (the collector's own, and the core's timeout when
// it runs programs), whose Save stages them in uci, as LuCI's own dialogs do; the page's
// Save & Apply applies them with the rest, and Dismiss drops them. A read-only login opens
// the dialog too, its fields and Save disabled, as LuCI's GridSection has it.
//
// What is saved states every setting: the main section's fields write their values even
// at the defaults (but for the TLS files and basic auth, which are unset without them).
// Basic auth's password is no field of the form, and its hash, which is saved apart from
// the exporter's config, where the app's ACL does not reach, is never shown: its row says
// whether one is saved, and its Change password and Remove password hand it to the
// object's set_password, which saves or removes the hash and has the service reload at
// once, apart from Save, Save & Apply and Revert, as LuCI's own root password is changed.
// A user emptied takes basic auth away, the saved hash left unused. A collector's
// `config collector '<module>'` section is there only while something differs from the
// defaults, its switch included, or a timeout is set; while it is, it holds the switch
// and every option the collector declares, each written out. timeout is written only
// when it is set: unset, it follows the collector's own default or the main section's
// exec_timeout, which writing it would pin.
//
// The object's `validate` checks values as the exporter reads them: the main section's
// while they are typed and again before Save, a dialog's while they are typed and again
// before it stages them. It answers what it refuses by a code and its arguments, which the
// page says in the user's language, naming the field by its title. Nothing the exporter
// would refuse is saved: a Save it refuses says why in a dialog, as LuCI's own Save error
// does, and above the form until it is fixed, each field by its tab, with a link that
// shows it; LuCI marks a tab that holds an invalid field with how many. Without the object (rpcd reloading, the package upgraded), the page
// is read-only.
//
// Collector names and help, package names, interfaces and paths come from the router: they
// reach E() only inside arrays, and never a form title or description, which LuCI renders
// as markup.

const CONFIG = exporter.CONFIG;
const lookup = exporter.lookup;
const fill = exporter.fill;
const alertBox = widgets.alertBox;
const line = widgets.line;

// How long typing pauses before the values are checked, in ms.
const CHECK_DELAY = widgets.CHECK_DELAY;

return view.extend({
	// A call that fails answers { failure }, which alerts() describes.
	load() {
		const failure = (err) => ({ failure: err });

		return Promise.all([
			exporter.collectors().catch(failure),
			exporter.interfaces().catch(failure),
			uci.load(CONFIG),
			exporter.password().catch(failure)
		]);
	},

	render([ data, ifaces, , password ]) {
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

		this.tabs = {
			general: _('General'),
			https: _('HTTPS & login'),
			limits: _('Limits'),
			collectors: _('Collectors')
		};
		this.tabOf = {};

		s.tab('general', this.tabs.general);
		s.tab('https', this.tabs.https, _('Basic auth needs HTTPS: set the certificate and key first.'));
		s.tab('limits', this.tabs.limits, _('Limits keep a slow or broken collector from costing the whole scrape.'));
		s.tab('collectors', this.tabs.collectors,
			_('Untick a collector to stop serving its metrics; Edit changes its options; Save & Apply applies them.'));

		this.renderMain(s, (L.isObject(ifaces) && Array.isArray(ifaces.interfaces)) ? ifaces.interfaces : []);
		this.mainOptions.auth_password.hashSaved = L.isObject(password) && password.saved === true;
		this.mainOptions.auth_password.tls = [ this.mainOptions.cert, this.mainOptions.key ];

		this.table = s.taboption('collectors', widgets.CollectorTable, '_collectors', '');
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

			// Basic auth's buttons follow the TLS files and the user as they are typed.
			node.addEventListener('input', () => this.mainOptions.auth_password.update('main'));

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

	// An option of the main section, on one of its tabs, which the object's validate may mark.
	option(s, tab, type, name, title, description) {
		const o = s.taboption(tab, type, name, title, description);

		this.mainOptions[name] = o;
		this.tabOf[name] = tab;
		o.validate = (section_id, value) => {
			const mark = lookup(this.marks, name);
			return (mark && mark.value === value) ? mark.message : true;
		};

		return o;
	},

	// Every field writes its value, even at the default, so the saved section states every
	// setting; but for the TLS files, unset without TLS. A field left empty is refused.
	renderMain(s, interfaces) {
		let o = this.option(s, 'general', form.Flag, 'enabled', _('Enable'), _('Runs the exporter.'));
		o.default = '1';
		o.rmempty = false;

		o = this.option(s, 'general', widgets.ListenSelect, 'listen_interface', _('Listen on'),
			_('The interface whose addresses serve the metrics, or every address. On loopback, only programs on the router can scrape it.'));
		o.default = 'loopback';
		o.interfaces = interfaces;

		o = this.option(s, 'general', form.Value, 'listen_port', _('Port'));
		o.datatype = 'port';
		o.default = '9100';
		o.placeholder = '9100';
		o.rmempty = false;

		o = this.option(s, 'general', form.Value, 'http_keepalive', _('Keep-alive'),
			_('Seconds an idle connection stays open; 0 closes it after each reply.'));
		o.datatype = 'uinteger';
		o.default = '70';
		o.placeholder = '70';
		o.rmempty = false;

		o = this.option(s, 'https', form.Value, 'cert', _('TLS certificate'),
			_('With a key, serves HTTPS; empty, plain HTTP. Both files must exist, and uhttpd needs a TLS library. LuCI\'s own are /etc/uhttpd.crt and /etc/uhttpd.key.'));
		o.datatype = 'file';

		o = this.option(s, 'https', form.Value, 'key', _('TLS key'), _('The private key of the certificate.'));
		o.datatype = 'file';

		// Basic auth's fields are shown without TLS too, and the object refuses them: LuCI
		// unsets an option whose depends are not met, which would drop the user and hash.
		const user = this.option(s, 'https', form.Value, 'auth_user', _('Basic auth user'),
			_('With a password, a scrape logs in as this user. Empty for none.'));
		user.placeholder = _('None');

		// Not the form's: its buttons save or remove the hash at once, through the object.
		o = this.option(s, 'https', widgets.PasswordAction, 'auth_password', _('Basic auth password'),
			_('Saved as a hash; the password itself is never stored. Changing or removing it applies at once, apart from Save & Apply.'));
		o.user = user;
		o.refusal = () => lookup(this.marks, 'auth_password')?.message ?? null;

		o = this.option(s, 'general', form.Flag, 'compress', _('Compress'),
			_('Gzip-compresses a scrape when the scraper asks for it, as Prometheus and vmagent do.'));
		o.default = '1';
		o.rmempty = false;

		o = this.option(s, 'general', form.Flag, 'omit_zero_values', _('Leave out zero values'),
			_('Leaves out counters that are 0, most of which never move on a router.'));
		o.default = '0';
		o.rmempty = false;

		o = this.option(s, 'limits', form.Value, 'scrape_timeout', _('Scrape timeout'),
			_('Seconds, 1 to 60, a scrape has to answer when the scraper does not say; Prometheus and vmagent do. Collectors left when the time is nearly spent are skipped, so the scrape still answers.'));
		o.datatype = 'range(1,60)';
		o.default = '10';
		o.placeholder = '10';
		o.rmempty = false;

		o = this.option(s, 'limits', form.Value, 'collector_budget', _('Collector budget'),
			_('Seconds, 1 to 60, a collector may take in a scrape. One that takes longer is quarantined: skipped for a few scrapes, then tried again.'));
		o.datatype = 'range(1,60)';
		o.default = '5';
		o.placeholder = '5';
		o.rmempty = false;

		o = this.option(s, 'limits', form.Value, 'exec_timeout', _('Program timeout'),
			_('Seconds, 1 to 30, that the programs a collector runs get in each scrape; one still running then is stopped, and its collector fails. A collector\'s Edit can set its own.'));
		o.datatype = 'range(1,30)';
		o.default = '5';
		o.placeholder = '5';
		o.rmempty = false;

		o = this.option(s, 'limits', form.Value, 'max_samples', _('Sample limit'),
			_('Samples, 1 to 100000, a collector may write in a scrape. One that writes more fails, and none of its samples are served.'));
		o.datatype = 'range(1,100000)';
		o.default = '20000';
		o.placeholder = '20000';
		o.rmempty = false;

		o = this.option(s, 'limits', form.Value, 'max_scrape_samples', _('Reply sample limit'),
			_('Samples, 1 to 1000000, the collectors of a scrape may write in all. A collector whose samples would go past it fails, and none of its samples are served; one left when it is reached is not run.'));
		o.datatype = 'range(1,1000000)';
		o.default = '200000';
		o.placeholder = '200000';
		o.rmempty = false;
	},

	// The form's values as the object's validate takes them: empty fields left out, as unset.
	// Basic auth's password is no field: the object checks the saved hash, which the page
	// may not read.
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

	// The title of a field of the main section, by its option's name.
	titleOf(name) {
		return String(lookup(this.mainOptions, name)?.title ?? name);
	},

	// What the object refuses of a field of the main section, as the page says it.
	refusalOf(name, refusal) {
		return exporter.problemText(refusal, this.titleOf(name), (n) => this.titleOf(n));
	},

	mark(candidate, errors) {
		this.marks = {};

		for (const name in (errors.main ?? {}))
			this.marks[name] = {
				value: candidate.main[name] ?? '',
				message: this.refusalOf(name, errors.main[name])
			};

		for (const name in this.mainOptions)
			this.mainOptions[name].triggerValidation('main');

		// LuCI counts a tab's invalid fields when a value changes, before this answer.
		ui.tabs.updateTabs(null, this.map.root);
	},

	// Why the settings could not be checked, above the form; a Save shows it in a dialog.
	showProblem(why) {
		this.problem = [ _('The settings could not be checked:'), ' ', why ];
		dom.content(this.panel, alertBox('error', this.problem));
	},

	// Shows a tab, and gives the focus to what `selector` finds on it; hides the Save error
	// dialog, which a link of it calls this from.
	reveal(tab, selector) {
		const root = this.map.root;

		ui.hideModal();
		root.querySelector(`.cbi-tabmenu > li.cbi-tab-disabled[data-tab="${tab}"] > a`)?.click();

		const target = root.querySelector(selector);
		if (target) {
			target.scrollIntoView({ block: 'center' });
			target.focus();
		}
	},

	// A link that shows a tab and a field of it, named by the tab and `children`. It takes
	// the colour of the text around it, underlined: a theme's link colour may not show on
	// its error alert (bootstrap's blue on red).
	revealLink(tab, selector, children) {
		return E('a', {
			'href': '#',
			'style': 'color:inherit;text-decoration:underline',
			'click': (ev) => {
				ev.preventDefault();
				this.reveal(tab, selector);
			}
		}, fill(_('%s → %s'), this.tabs[tab], children));
	},

	// What the object found, in a list above the form, which stays until it is fixed, and
	// in a dialog, which the user sees wherever the page is scrolled. Each field is named
	// by its tab and its title, a collector's option by its collector's title too, as a
	// link that shows it.
	showRefused(errors) {
		const items = () => {
			const out = [];

			for (const name in (errors.main ?? {})) {
				const o = lookup(this.mainOptions, name);
				const where = o ? this.revealLink(this.tabOf[name],
					`.cbi-value[data-name="${CSS.escape(name)}"] :is(input:not([type="hidden"]), select, textarea, .cbi-dropdown, button)`,
					[ o.title ]) : name;

				out.push(line([ where, ': ', this.refusalOf(name, errors.main[name]) ]));
			}

			for (const id in (errors.collectors ?? {}))
				for (const name in errors.collectors[id]) {
					const c = this.table.collectors.find((c) => c?.id === id);
					const row = `tr[data-collector="${CSS.escape(id)}"]`;
					const target = (name === 'enabled') ? `${row} input[type="checkbox"]` : `${row} .cbi-button-edit`;

					out.push(line([
						this.revealLink('collectors', target, fill(_('%s → %s'), String(c?.title || c?.name || id), exporter.optionTitle(c, name))),
						': ', exporter.problemText(errors.collectors[id][name], exporter.optionTitle(c, name), (n) => exporter.optionTitle(c, n))
					]));
				}

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
