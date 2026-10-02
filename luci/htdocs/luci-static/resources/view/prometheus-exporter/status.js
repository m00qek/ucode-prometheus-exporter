'use strict';
'require view';
'require ui';
'require dom';
'require prometheus-exporter as exporter';

// Status → Prometheus exporter: whether the service runs and where it serves /metrics,
// and how each collector did in a test run the plugin's `status` runs on the router. The
// test run happens when the page opens and on Refresh only, never on a timer. It is not
// the service's: it runs outside the service's jail and without its deadline. Apart from
// it, the Service's scrapes column says what the service's own scrapes found, from its
// running instance's state: a collector quarantined, and one the scrape deadline left
// out lately.
//
// A banner above the tables says what needs attention: the service enabled and not
// running, the collectors that failed, and those the service quarantined. The rows are
// grouped by how they did, worst first, and sorted by title within a group.
//
// Collector names, errors and paths come from the router: they reach E() only inside
// arrays.

const fill = exporter.fill;

// What the error codes mean, in the docs of this release.
const ERROR_CODES = 'https://m00qek.github.io/ucode-prometheus-exporter/0.1/reference/error-codes/';

// No class makes a label red in every theme: material has `label danger`, bootstrap no
// red label at all. So Failed also takes the theme's own error colour, from its variables:
// bootstrap's, then those of material and openwrt2020. A theme with neither shows a plain
// label, which says Failed in words all the same.
const FAIL_STYLE = 'background-color:var(--error-color-high,var(--danger-color));color:var(--on-error-color,var(--on-danger-color))';

// The scrapes after which the deadline leaving a collector out is old news, as `check`
// has it (prometheus_exporter.ledger's RECENT).
const RECENT = 10;

// The groups of rows, in the order the table shows them.
const FAILED = 0, SERVICE = 1, OK = 2, IDLE = 3, OFF = 4;

function alertBox(kind, children) {
	return E('div', { 'class': 'alert-message ' + kind }, children);
}

function label(kind, text, style) {
	return E('span', { 'class': 'label ' + kind, 'style': style ?? null }, [ text ]);
}

// A label in a table cell, above more lines: as a block of its own, so that a theme's
// padding of labels does not overlap the line below.
function badge(kind, text, style) {
	return line([ label(kind, text, 'display:inline-block' + (style ? ';' + style : '')) ]);
}

// A page to go to from a banner, as a button: a theme's link colour may not read on
// the banner's own.
function action(path, text) {
	return E('a', { 'class': 'btn cbi-button', 'href': L.url(path) }, [ text ]);
}

function yesNo(value, yes, no, unknown) {
	return (value === true) ? label('success', yes) : (value === false) ? label('warning', no) : E('em', {}, [ unknown ]);
}

function section(title, children) {
	return E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ title ]) ].concat(children));
}

function row(title, children) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, [ title ]),
		E('td', { 'class': 'td left' }, children)
	]);
}

function line(children) {
	return E('div', {}, children);
}

function titleOf(c) {
	return String(c.title || c.name || '');
}

function isQuarantined(c) {
	return L.isObject(c.service) && c.service.quarantined === true;
}

function isLate(c) {
	return L.isObject(c.service) && typeof(c.service.late) === 'number' && c.service.late < RECENT;
}

// Which group a collector's row is in: failed in the test run; quarantined or left out
// lately by the service; OK; nothing to observe; not run.
function groupOf(c) {
	if (c.success === false)
		return FAILED;
	if (isQuarantined(c) || isLate(c))
		return SERVICE;
	if (c.success === true)
		return (c.observing === false) ? IDLE : OK;
	return OFF;
}

// An error as the exporter writes it, `CODE (detail)` or `CODE`, for the user: the detail
// first, in words, then the code, which links to what it means. A code the page does not
// know is linked all the same; text of any other shape is shown as it is.
function errorText(text) {
	const s = String(text ?? '');
	const m = /^([A-Z][A-Z0-9_]*)(?: \(([\s\S]*)\))?$/.exec(s);

	if (!m)
		return [ line([ E('small', {}, [ s ]) ]) ];

	const code = E('a', { 'href': ERROR_CODES, 'target': '_blank', 'rel': 'noreferrer' }, [ m[1] ]);

	return [
		(m[2] != null && m[2] !== '') ? line([ m[2] ]) : '',
		line([ E('small', {}, fill(_('Error code: %s'), code)) ])
	];
}

// What the jail mounts for a collector, folded away: it matters when a collector that
// fails here, or fails only in the service, needs a path the jail does not give it.
function mountsOf(c) {
	const mounts = Array.isArray(c.mounts) ? c.mounts : [];

	if (!mounts.length)
		return '';

	return E('details', {}, [
		E('summary', {}, [ E('small', {}, [ _('Jail mounts (%d)').format(mounts.length) ]) ]),
		E('div', {}, mounts.map((m) => line([ E('code', {}, [ String(m) ]) ])))
	]);
}

// How a collector did in the test run: OK, Failed (with why), Nothing to observe (a
// success whose hardware, kernel feature or service is not there, with why) or Not run.
// Each says it in words.
function outcome(c) {
	if (c.success === false)
		return [ badge('danger error', _('Failed'), FAIL_STYLE), ...errorText(c.error), mountsOf(c) ];

	if (c.success === true && c.observing === false)
		return [ line([ E('em', {}, [ _('Nothing to observe') ]) ]), line([ E('small', {}, [ String(c.reason ?? '') ]) ]) ];

	if (c.success === true)
		return [ label('success', _('OK')) ];

	return [ E('em', {}, [ _('Not run: switched off') ]) ];
}

// What the service's own scrapes found of a collector (the plugin's `service`), each in
// words that name the service, as a theme may show the cell without its heading.
function serviceState(c) {
	const s = c.service;
	const out = [];

	if (isQuarantined(c))
		out.push(E('div', {}, [
			badge('warning', _('Quarantined')),
			line([ E('small', {}, [ (s.retry_in > 1)
				? _('The service tries it again in %d scrapes.').format(s.retry_in)
				: _('The service tries it again at its next scrape.') ]) ]),
			...((s.reason != null && s.reason !== '') ? errorText(s.reason) : [])
		]));

	if (isLate(c))
		out.push(E('div', {}, [
			badge('notice', _('Left out at the deadline')),
			line([ E('small', {}, [ (s.late === 0)
				? _('In the service\'s last scrape.')
				: _('%d of the service\'s scrapes ago.').format(s.late) ]) ])
		]));

	return out;
}

function duration(secs) {
	if (typeof(secs) !== 'number')
		return '';

	return (secs < 1) ? _('%d ms').format(Math.round(secs * 1000)) : _('%.2f s').format(secs);
}

// A cell, with its column's heading for narrow screens only when it has something under
// it: a theme that shows headings in each row would show an empty one otherwise.
function cell(title, children) {
	const empty = children.every((ch) => ch === '' || ch == null);

	return E('td', { 'class': 'td', 'data-title': (empty || title == null) ? null : title }, empty ? [ '' ] : children);
}

// The titles of collectors, for a sentence, between commas: each a text node.
function titles(list) {
	const out = [];

	list.forEach((c, i) => {
		if (i > 0)
			out.push(', ');
		out.push(E('strong', {}, [ titleOf(c) ]));
	});

	return out;
}

// A listen URL as the browser can open it: every address (*) is the one this page
// came from.
function openable(url) {
	const host = /:/.test(window.location.hostname) ? `[${window.location.hostname}]` : window.location.hostname;
	return String(url).replace(/^(https?):\/\/\*:/, `$1://${host}:`);
}

function onRouterOnly(url) {
	return /^https?:\/\/(127\.[0-9.]+|\[::1\]):/.test(url);
}

function link(path, text) {
	return E('a', { 'href': L.url(path) }, [ text ]);
}

return view.extend({
	load() {
		return this.fetch();
	},

	fetch() {
		return exporter.status().catch((err) => ({ error: 'RPC_FAILED', message: exporter.describeError(err) }));
	},

	render(status) {
		this.body = E('div', {}, []);
		this.update(status);

		return E([], [
			E('h2', { 'name': 'content' }, [ _('Prometheus exporter') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('This page runs each enabled collector once, when it opens and on Refresh: a test run on the router.'), ' ',
				_('The test run is not the service\'s: it runs outside the service\'s jail and without its deadline, so its results can differ from what Prometheus gets.'), ' ',
				...fill(_('The settings are under %s.'), link('admin/services/prometheus-exporter', _('Services → Prometheus exporter')))
			]),
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleRefresh')
				}, [ _('Refresh') ])
			]),
			this.body
		]);
	},

	handleRefresh(ev) {
		return this.fetch().then((status) => this.update(status));
	},

	update(status) {
		if (!L.isObject(status) || status.error != null || !L.isObject(status.service)) {
			dom.content(this.body, alertBox('error', [
				_('The status of the exporter could not be read:'), ' ', String(status?.message ?? status?.error ?? '')
			]));
			return;
		}

		const collectors = Array.isArray(status.collectors) ? status.collectors : [];

		dom.content(this.body, [
			E('div', { 'class': 'exporter-banners' }, this.renderBanners(status.service, collectors)),
			this.renderService(status),
			this.renderCollectors(collectors)
		]);
	},

	// What needs attention, worst first: the service enabled and not running, or switched
	// off; the collectors that failed in the test run; those the service quarantined.
	renderBanners(svc, collectors) {
		const out = [];
		const failed = collectors.filter((c) => c.success === false).sort((a, b) => titleOf(a).localeCompare(titleOf(b)));
		const quarantined = collectors.filter(isQuarantined).sort((a, b) => titleOf(a).localeCompare(titleOf(b)));

		if (svc.running === false && svc.enabled === true)
			out.push(alertBox('error', [
				E('h4', {}, [ _('The exporter is enabled but not running: Prometheus gets nothing.') ]),
				E('p', {}, [ _('Start it under System → Startup; the system log may say why it stopped.') ]),
				E('div', {}, [ action('admin/system/startup', _('System → Startup')), ' ', action('admin/status/logs', _('System log')) ])
			]));
		else if (svc.running === false && svc.enabled === false)
			out.push(alertBox('notice', [
				E('p', {}, [ _('The exporter is switched off in its settings, so Prometheus gets nothing. Enable it under Services → Prometheus exporter.') ]),
				E('div', {}, [ action('admin/services/prometheus-exporter', _('Services → Prometheus exporter')) ])
			]));

		if (failed.length)
			out.push(alertBox('warning', [
				E('p', {}, fill(N_(failed.length, '%s collector failed in the test run: %s.', '%s collectors failed in the test run: %s.'),
					String(failed.length), titles(failed))),
				E('p', {}, [ N_(failed.length, 'It is first in the table below, with why.', 'They are first in the table below, with why.') ])
			]));

		if (quarantined.length)
			out.push(alertBox('notice', [
				E('p', {}, fill(N_(quarantined.length, 'The service quarantined %s collector: %s.', 'The service quarantined %s collectors: %s.'),
					String(quarantined.length), titles(quarantined))),
				E('p', {}, [ _('The service leaves a quarantined collector out of its scrapes until it tries it again; a restart of the service tries it at once.') ])
			]));

		return out;
	},

	renderService(status) {
		const svc = status.service;
		const listen = Array.isArray(status.listen) ? status.listen : [];
		const running = (svc.running === true)
			? label('success', _('Running'))
			: (svc.running === false) ? label('warning', _('Not running'))
			: E('span', {}, [ E('em', {}, [ _('Unknown') ]), ' ', E('small', {}, [ String(svc.error ?? '') ]) ]);

		const urls = listen.length ? listen.map((url) => E('div', {}, [
			E('a', { 'href': openable(url), 'target': '_blank', 'rel': 'noreferrer' }, [ openable(url) ]),
			onRouterOnly(url) ? E('small', {}, [ ' ', _('(reachable from the router only)') ]) : ''
		])) : [ E('em', {}, [ (svc.running === true) ? _('No address') : _('Not served while the exporter is not running') ]) ];

		return section(_('Service'), [
			E('table', { 'class': 'table' }, [
				row(_('State'), [ running ]),
				row(_('Enabled in the settings'), [ yesNo(svc.enabled, _('Yes'), _('No'), _('Invalid setting')) ]),
				row(_('Starts at boot'), [ yesNo(svc.boot, _('Yes'), _('No'), _('Unknown')) ]),
				row(_('Metrics'), urls),
				row(_('Basic auth'), [ (svc.auth === true) ? _('A scrape logs in, over HTTPS') : (svc.auth === false) ? _('None') : _('Invalid setting') ]),
				row(_('Compression'), [ (svc.compress === true) ? _('gzip, when the scraper asks for it') : (svc.compress === false) ? _('Off') : _('Invalid setting') ])
			])
		]);
	},

	renderCollectors(collectors) {
		const headers = [ _('Collector'), _('Test run'), _('Duration'), _('Service\'s scrapes') ];
		const sorted = collectors.map((c) => ({ c: c, group: groupOf(c), title: titleOf(c) }))
			.sort((a, b) => (a.group - b.group) || a.title.localeCompare(b.title));

		// The collector's name needs no heading above it.
		const rows = sorted.map((r, i) => E('tr', {
			'class': 'tr cbi-rowstyle-' + (1 + i % 2), 'data-collector': String(r.c.id), 'data-group': String(r.group)
		}, [
			cell(null, exporter.nameOf(r.c)),
			cell(headers[1], outcome(r.c)),
			cell(headers[2], [ duration(r.c.duration) ]),
			cell(headers[3], serviceState(r.c))
		]));

		// The test run's counts: a collector the service quarantined counts by how it did here.
		const count = (pred) => collectors.filter(pred).length;
		const summary = _('%d failed, %d OK, %d with nothing to observe, %d off.').format(
			count((c) => c.success === false),
			count((c) => c.success === true && c.observing !== false),
			count((c) => c.success === true && c.observing === false),
			count((c) => c.success == null));

		return section(_('Collectors'), [
			E('p', { 'class': 'exporter-summary' }, [ summary ]),
			E('p', {}, [
				_('The Test run column is this page\'s run of each collector. The Service\'s scrapes column is what the service\'s own scrapes found: a collector it quarantined, and one its scrape deadline left out lately.')
			]),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, headers.map((h) => E('th', { 'class': 'th' }, [ h ])))
			].concat(rows.length ? rows : [
				E('tr', { 'class': 'tr placeholder' }, [
					E('td', { 'class': 'td', 'colspan': String(headers.length) }, [ E('em', {}, [ _('No collector is installed.') ]) ])
				])
			]))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
