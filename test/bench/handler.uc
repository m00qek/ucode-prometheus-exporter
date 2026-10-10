{%
'use strict';

// uhttpd's ucode handler for the benchmark's handler: cases (run.uc): the
// service's handler (files/usr/libexec/prometheus-exporter/handler.uc), the
// collectors reading a world rather than the system. uhttpd runs this once,
// then handle_request in a process of its own per request, as it runs the
// service's.
//
// BENCH_HANDLER names a JSON file run.uc wrote: { search, world, collectors,
// state }: the module search path of the exporter and the bench (uhttpd
// compiles this file with its own), the world's directory, the directory of
// the set's collectors, and the state's.

import { readfile } from 'fs';

const cfg = json(readfile(getenv('BENCH_HANDLER')));
const mods = loadstring(
	"import { handler } from 'prometheus.exporter.app';\n" +
	"import { head } from 'prometheus.exporter.http';\n" +
	"import * as world from 'bench.world';\n" +
	'return { handler, head, world };',
	{ raw_mode: true, module_search_path: cfg.search })();

const world = mods.world.load(cfg.world);
const app = mods.handler((level, msg) => null, cfg.collectors, cfg.state,
	{ observed: mods.world.modules(world, [], { lazy: true }) });

global.handle_request = function(env) {
	const reply = app.handle(env);

	uhttpd.send(mods.head(reply), reply.body);
};
-%}
