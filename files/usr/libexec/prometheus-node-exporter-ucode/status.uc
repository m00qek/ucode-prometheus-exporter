#!/usr/bin/ucode
'use strict';

// What `service prometheus-node-exporter-ucode status` adds for a running
// exporter: where it listens, and how many collectors it serves.

import * as deps from 'node_exporter.deps';
import * as loader from 'node_exporter.loader';
import * as config from 'node_exporter.config';
import * as check from 'node_exporter.check';
import * as Result from 'node_exporter.result';

const mods = deps.modules();
const ubus = deps.ubus_channel(mods.ubus.connect);
const res = ubus.call('service', 'list', { name: config.PACKAGE });

ubus.close();

if (!res.ok) {
	warn(`${config.PACKAGE}: cannot read its instance: ${Result.describe(res)}\n`);
	exit(1);
}

const instances = values(res.data?.[config.PACKAGE]?.instances ?? {});
const collectors = loader.load(mods.fs, loader.DIR, loader.import_module, () => null);

print(check.status(instances[0]?.command ?? [], collectors, mods.uci.cursor()), '\n');
