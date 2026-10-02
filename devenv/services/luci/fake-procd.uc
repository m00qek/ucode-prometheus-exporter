#!/usr/bin/ucode
'use strict';

// Stands in for procd (and netifd) in the browser tests' container, where nothing boots it. It
// publishes procd's `system` object, which LuCI's page header and Overview read, and
// its `service` object, whose `list` answers the exporter's instance from a fixture,
// $FIXTURES/service/<name>.json, as procd would. The plugin asks `service list`
// whether the exporter runs and where it listens; the exporter itself does not run.
//
// `exporter.fixture` lets the tests switch that fixture (`service {name}`; the name
// `none` withdraws `service`, as when procd cannot be asked), lay out the exporter's
// config from $FIXTURES/config/<name> (`config {name}`; `default` puts back the one
// the container started with) and read it back as it is on disk (`read`). `state {name}`
// lays out $FIXTURES/state/<name>.json as the ledger of a running instance of the
// exporter (prometheus_exporter.ledger), in its state directory, as its scrapes would
// leave it; `none` removes it.

import * as ubus from 'ubus';
import * as uloop from 'uloop';
import { readfile, writefile, mkdir, unlink, lsdir } from 'fs';

const DIR = getenv('FIXTURES') ?? '/fixtures';
const CONFIG = '/etc/config/prometheus-exporter';
const MB = 1024 * 1024;
// The exporter's state directory (prometheus_exporter.state), and an instance's id in it.
const STATE_DIRS = [ '/var/run/prometheus-exporter', '/var/run/prometheus-exporter/state' ];
const INSTANCE = '4242-123456';

const BOARD = {
	kernel: '6.12.0',
	hostname: 'office',
	system: 'x86_64',
	model: 'Browser test container',
	board_name: 'prometheus-exporter-browser-tests',
	rootfs_type: 'overlay',
	release: {
		distribution: 'OpenWrt',
		version: '25.12.5',
		revision: 'r0',
		target: 'x86/64',
		description: 'OpenWrt 25.12.5',
	},
};

uloop.init();
const conn = ubus.connect();
const at_start = readfile(CONFIG);
let reply = null;
let service = null;

function is_name(name) {
	return type(name) == 'string' && match(name, /^[a-z0-9-]+$/) != null;
}

function use_service(name) {
	if (name == 'none') {
		service?.remove();
		service = null;
		return true;
	}

	if (!is_name(name))
		return false;

	let data = readfile(`${DIR}/service/${name}.json`);
	if (data == null)
		return false;

	reply = json(data);
	service ??= conn.publish('service', {
		list: { args: { name: '', verbose: false }, call: (req) => (req.args.name == null || req.args.name in keys(reply)) ? reply : {} },
		event: { args: { type: '', data: {} }, call: () => null },
	});
	return true;
}

function lay_out(name) {
	if (!is_name(name))
		return false;

	let data = (name == 'default') ? at_start : readfile(`${DIR}/config/${name}`);
	return data != null && writefile(CONFIG, data) != null;
}

function use_state(name) {
	let dir = STATE_DIRS[1];

	for (let f in lsdir(dir) ?? [])
		unlink(`${dir}/${f}`);

	if (name == 'none')
		return true;
	if (!is_name(name))
		return false;

	let data = readfile(`${DIR}/state/${name}.json`);
	if (data == null)
		return false;

	for (let d in STATE_DIRS)
		mkdir(d, 0o700);

	return writefile(`${dir}/${INSTANCE}.scrape`, data) != null;
}

conn.publish('system', {
	board: { args: { ubus_rpc_session: '' }, call: () => BOARD },
	info: {
		args: { ubus_rpc_session: '' },
		call: () => ({
			localtime: time(),
			uptime: 22440,
			load: [ 8192, 4096, 2048 ],
			memory: { total: 512 * MB, free: 300 * MB, shared: 4 * MB, buffered: 8 * MB, available: 360 * MB, cached: 60 * MB },
			root: { total: 100 * 1024, free: 80 * 1024, used: 20 * 1024, avail: 80 * 1024 },
			tmp: { total: 256 * 1024, free: 250 * 1024, used: 6 * 1024, avail: 250 * 1024 },
			swap: { total: 0, free: 0 },
		}),
	},
});

// netifd's protocols and interfaces, which LuCI's network picker reads.
const PROTOCOLS = { static: { no_device: false }, dhcp: { no_device: false }, none: { no_device: false } };
const INTERFACES = [
	{ interface: 'loopback', up: true, pending: false, available: true, proto: 'static', device: 'lo', l3_device: 'lo',
		'ipv4-address': [ { address: '127.0.0.1', mask: 8 } ], 'ipv6-address': [], route: [], 'dns-server': [] },
	{ interface: 'lan', up: true, pending: false, available: true, proto: 'static', device: 'br-lan', l3_device: 'br-lan',
		'ipv4-address': [ { address: '192.168.1.1', mask: 24 } ], 'ipv6-address': [], route: [], 'dns-server': [] },
	{ interface: 'wan', up: false, pending: false, available: true, proto: 'dhcp', device: 'eth1',
		'ipv4-address': [], 'ipv6-address': [], route: [], 'dns-server': [] },
];

conn.publish('network', {
	get_proto_handlers: { args: {}, call: () => PROTOCOLS },
});

conn.publish('network.interface', {
	dump: { args: {}, call: () => ({ interface: INTERFACES }) },
});

conn.publish('exporter.fixture', {
	service: { args: { ubus_rpc_session: '', name: '' }, call: (req) => ({ ok: use_service(req.args.name) }) },
	config: { args: { ubus_rpc_session: '', name: '' }, call: (req) => ({ ok: lay_out(req.args.name) }) },
	read: { args: { ubus_rpc_session: '' }, call: () => ({ data: readfile(CONFIG) }) },
	state: { args: { ubus_rpc_session: '', name: '' }, call: (req) => ({ ok: use_state(req.args.name) }) },
});

if (!use_service(getenv('SERVICE') ?? 'running'))
	die(`no service fixture ${getenv('SERVICE') ?? 'running'} in ${DIR}/service`);

uloop.run();
