'use strict';
'require view';
'require ui';
'require dom';
'require prometheus-exporter as exporter';

// Status → Prometheus exporter: whether the service runs and where it serves /metrics,
// and how each collector did in a scrape the plugin's `status` runs on the router. The
// scrape runs when the page opens and on Refresh only, never on a timer.
//
// Collector names, errors and paths come from the router: they reach E() only inside
// arrays.

const fill = exporter.fill;

// No class makes a label red in every theme: material has `label danger`, bootstrap no
// red label at all. So Failed also takes the error colour of the theme's own variable:
// bootstrap's, then openwrt2020's (as wgpathd does).
const FAIL_STYLE = 'background-color:var(--error-color-high,var(--danger-color,#c43c35));color:var(--on-error-color,#fff)';

function alertBox(kind, children) {
	return E('div', { 'class': 'alert-message ' + kind }, children);
}

function label(kind, text, style) {
	return E('span', { 'class': 'label ' + kind, 'style': style ?? null }, [ text ]);
}

function yesNo(value, yes, no, unknown) {
	return (value === true) ? label('success', yes) : (value === false) ? label('warning', no) : label('', unknown);
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

// How a collector did in the scrape: OK, Failed, or Nothing to observe (a success
// whose hardware, kernel feature or service is not there), with why.
function outcome(c) {
	if (c.success === true && c.observing === false)
		return [ label('', _('Nothing to observe')), E('div', {}, [ E('small', {}, [ String(c.reason ?? '') ]) ]) ];

	return [
		(c.success === true) ? label('success', _('OK'))
			: (c.success === false) ? label('danger', _('Failed'), FAIL_STYLE)
			: E('em', {}, [ _('Not run') ])
	];
}

function duration(secs) {
	if (typeof(secs) !== 'number')
		return '';

	return (secs < 1) ? _('%d ms').format(Math.round(secs * 1000)) : _('%.2f s').format(secs);
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
				_('Each enabled collector runs once when this page opens and on Refresh, on the router but outside the service\'s jail.'), ' ',
				...fill(_('The settings are under %s.'),
					E('a', { 'href': L.url('admin/services/prometheus-exporter') }, [ _('Services → Prometheus exporter') ]))
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

		dom.content(this.body, [ this.renderService(status), this.renderCollectors(status.collectors ?? []) ]);
	},

	renderService(status) {
		const svc = status.service;
		const listen = Array.isArray(status.listen) ? status.listen : [];
		const running = (svc.running === true)
			? label('success', _('Running'))
			: (svc.running === false) ? label('warning', _('Not running'))
			: E('span', {}, [ label('', _('Unknown')), ' ', E('small', {}, [ String(svc.error ?? '') ]) ]);

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
		const headers = [ _('Collector'), _('Enabled'), _('Last scrape'), _('Duration'), _('Error'), _('Jail mounts') ];
		const rows = collectors.map((c, i) => E('tr', { 'class': 'tr cbi-rowstyle-' + (1 + i % 2), 'data-collector': String(c.id) }, [
			E('td', { 'class': 'td', 'data-title': headers[0] }, exporter.nameOf(c)),
			E('td', { 'class': 'td', 'data-title': headers[1] }, [ c.enabled ? _('Yes') : _('No') ]),
			E('td', { 'class': 'td', 'data-title': headers[2] }, outcome(c)),
			E('td', { 'class': 'td', 'data-title': headers[3] }, [ duration(c.duration) ]),
			E('td', { 'class': 'td', 'data-title': headers[4] }, [ c.error ? E('small', {}, [ String(c.error) ]) : '' ]),
			E('td', { 'class': 'td', 'data-title': headers[5] }, (Array.isArray(c.mounts) && c.mounts.length)
				? c.mounts.map((m) => E('div', {}, [ E('code', {}, [ String(m) ]) ]))
				: [ '' ])
		]));

		const failed = collectors.filter((c) => c.success === false).length;
		const ran = collectors.filter((c) => c.success != null).length;
		const idle = collectors.filter((c) => c.success === true && c.observing === false).length;

		return section(_('Collectors'), [
			E('p', {}, fill(_('%s of %s collectors that ran succeeded.'), String(ran - failed), String(ran)).concat(idle
				? [ ' ' ].concat(fill(_('%s had nothing to observe: their hardware, kernel feature or service is not there.'), String(idle)))
				: [])),
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
