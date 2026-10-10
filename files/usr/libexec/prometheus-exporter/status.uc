#!/usr/bin/ucode
'use strict';

import * as deps from 'prometheus.exporter.deps';
import * as config from 'prometheus.exporter.config';
import { load } from 'prometheus.exporter.app';
import * as check from 'prometheus.exporter.check';
import * as Result from 'prometheus.exporter.result';

const mods = deps.modules();
const ubus = deps.ubus_channel(mods.ubus.connect);
const res = ubus.call('service', 'list', { name: config.NAME });

ubus.close();

if (!res.ok) {
	warn(`${config.NAME}: cannot read its instance: ${Result.describe(res)}\n`);
	exit(1);
}

const instances = check.exporters(values(res.data?.[config.NAME]?.instances ?? {}));
const collectors = load(mods, null, () => null);

print(check.status(instances[0]?.command ?? [], collectors, mods.uci.cursor()), '\n');
