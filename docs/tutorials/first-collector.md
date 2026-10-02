# Write Your First Collector

In this tutorial we will write a collector, `tasks`, that counts the tasks the kernel has, from `/proc/loadavg`. We will run it on the command line, test it, package it, and see it served by OpenWrt in the lab, in LuCI and at `/metrics`. Along the way we will meet the development environment: `make shell`, `make test`, `test/context.uc`, `make docs-gen` and `make lab`.

It takes about half an hour, most of it waiting for builds. At the end we will remove what we made: this collector is practice.

## What you need

- A checkout of the repository, and a terminal in it.
- Docker, and `make`. Everything else runs in containers.
- About 3 GB of disk for the images, the first time.

---

## 1. Run the tests

First, make sure everything works before we change anything:

```bash
make test
```

The first run builds the development image, OpenWrt's own, which takes a minute or two. Then the tests run, and the last lines say how they went:

```
Summary:

  1146 successes / 0 failures / 0 errors / 0 skipped / 0 ignored (49301 ms)
```

Your numbers will differ. What matters is `0 failures`.

## 2. Look at the source

Our collector will read the fourth field of `/proc/loadavg`. Let's see it, in the development image:

```bash
make shell
```

```sh
cat /proc/loadavg
```

```
0.72 0.61 0.97 2/3199 81234
```

The fourth field, `2/3199`, is the tasks that are runnable now and the tasks that exist. Leave the shell with `exit`.

## 3. Write the collector

Create `src/prometheus_exporter/collectors/tasks.uc`:

```js
'use strict';

import { Result, errors, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'tasks',
	title: 'Scheduler tasks',
	help: 'Runnable and existing tasks, from /proc/loadavg.',
	needs: [ 'fs' ],
};

export function collect(deps, out) {
	let line = proc.first_line(deps.fs, '/proc/loadavg');

	if (line == null)
		return Result.err(errors.SOURCE_UNREADABLE, '/proc/loadavg');

	let counts = split(proc.fields(line)[3] ?? '', '/');

	if (length(counts) != 2)
		return Result.err(errors.SOURCE_INVALID, `/proc/loadavg: ${line}`);

	out.gauge('node_tasks_runnable', 'Tasks that are runnable now.')(null, counts[0]);
	out.gauge('node_tasks', 'Tasks that exist now.')(null, counts[1]);

	return Result.ok();
};
```

Notice four things. The collector imports one module, `prometheus_exporter.api`, the collector API: what it uses of the exporter comes from there. `meta.needs` asks for `fs`, and `collect` reads the file through `deps.fs`, not by importing `fs`: a collector only gets what it asks for, and the exporter refuses one that imports anything else. `out.gauge` declares a family and returns a function that records a sample. And `collect` returns a Result: `Result.ok()` when it worked, `Result.err()` with a code when it did not.

## 4. Run it

Back in the development image:

```bash
make shell
```

```sh
ucode -L /exporter/src files/usr/bin/prometheus-exporter scrape -d src/prometheus_exporter/collectors tasks
```

This is the exporter's own command, run from the source tree, with the collectors of `src/` and only ours. It prints a scrape:

```
# HELP node_tasks_runnable Tasks that are runnable now.
# TYPE node_tasks_runnable gauge
node_tasks_runnable 2
# HELP node_tasks Tasks that exist now.
# TYPE node_tasks gauge
node_tasks 3199
# HELP node_scrape_collector_duration_seconds node_exporter: Duration of a collector scrape.
...
node_scrape_collector_success{collector="tasks"} 1
...
ucode_prometheus_exporter_build_info{version="dev"} 1
```

Our two families come first, then what every scrape says of each collector that ran: ours succeeded. The version is `dev`, as it is from a source tree.

Now let the exporter check our module against the rules it holds every collector to, as it would before anyone installs it:

```sh
ucode -L /exporter/src files/usr/bin/prometheus-exporter collector check src/prometheus_exporter/collectors/tasks.uc
```

```
ok   strict mode: 'use strict' first
ok   imports: prometheus_exporter.api alone
ok   load: 0.001 s, of at most 5 s
ok   meta: tasks (Scheduler tasks), needs fs, budget 5 s, max_samples 20000
ok   run: 0.000 s, 2 samples in 2 families
ok   families: node_tasks_runnable node_tasks
ok   exposition: valid text, each series once
```

Every line is `ok`: it imports the API alone, it loads quickly, its `meta` is valid, it ran in a process of its own well within its budget, and it wrote two families no installed collector writes. Had it looped, or written `node_load1`, a line would say `FAIL`, and why. `exit` the shell.

## 5. Test it

Tests run the collector the way a scrape does, with fakes in place of the system: `test/context.uc` gives them. Create `test/unit/prometheus_exporter/collectors/tasks_test.uc`:

```js
'use strict';

import { describe, it, assert } from 'utest';
import { with_collector } from 'context';
import * as tasks from 'prometheus_exporter.collectors.tasks';

describe('collectors.tasks', () => {
	it('counts the runnable and the existing tasks', () => {
		with_collector(tasks, { fs: { data: { '/proc/loadavg': '0.08 0.03 0.00 2/131 4567\n' } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_tasks_runnable Tasks that are runnable now.',
				'# TYPE node_tasks_runnable gauge',
				'node_tasks_runnable 2',
				'# HELP node_tasks Tasks that exist now.',
				'# TYPE node_tasks gauge',
				'node_tasks 131',
			], r.lines);
		});
	});

	it('fails with SOURCE_UNREADABLE when /proc/loadavg cannot be read', () => {
		with_collector(tasks, { fs: { data: { '/proc/loadavg': null } } }, (r) => {
			assert.match('SOURCE_UNREADABLE', r.result.error);
			assert.match([ "collector 'tasks': SOURCE_UNREADABLE (/proc/loadavg)" ], r.logs);
		});
	});
});
```

`with_collector` hands the collector an `fs` that answers from `data`, runs it, and gives us what it wrote: `r.result`, `r.lines`, and `r.logs`, what the scrape would log. The second test hands it a file that cannot be read. `with_collector` also answers as the exporter's jail would: had our collector read a file outside `/proc` and `/sys` without declaring it, the test would fail, and say so. Run only these:

```bash
make unit MODULES=test/unit/prometheus_exporter/collectors/tasks_test.uc
```

```
  2 successes / 0 failures / 0 errors / 0 skipped / 0 ignored (90 ms)
```

## 6. Package it

Now the whole suite:

```bash
make test
```

It fails, as it should. Among its output:

```
    ■ docs_gen.main.run > finds the notes and the code in agreement
        Expected 0 elements, got 1
...
    ■ collectors > tasks > is in the generated reference
        run make docs-gen: docs/reference/collectors.md has no tasks
    ■ collectors > tasks > is packaged once: in the base package or as its own, named after it
        tasks: base false, subpackage null
```

`test/integration/collectors_test.uc` holds every collector to what the repository owes it, and the documentation's generator finds a collector in no package. Ours has no package yet. Open `openwrt/ucode-prometheus-exporter/Makefile`, find the `Collector` lines, and add ours after `sockstat`'s:

```makefile
$(eval $(call Collector,tasks,tasks,scheduler tasks,))
```

That makes a package, `ucode-prometheus-exporter-tasks`. Then write the reference pages again, which the code decides:

```bash
make docs-gen
```

```
wrote docs/reference/collectors.md
wrote docs/reference/error-codes.md
wrote docs/reference/metrics.md
```

Open `docs/reference/metrics.md` and find the section of `tasks`: our two families are there, with their type and help, as the collector wrote them when the generator ran it on the captures of real routers in `test/fixtures/`. Now:

```bash
make test
```

The summary says `0 failures` again.

## 7. See it on OpenWrt

The lab is OpenWrt under procd, in a container, with every package installed:

```bash
make lab
```

It builds the packages with OpenWrt's SDK, which takes a few minutes the first time, boots OpenWrt and installs them. It ends with:

```
The lab runs, as container ucode-prometheus-exporter-lab:
  LuCI      http://127.0.0.1:8080/  (root, no password)
  /metrics  http://127.0.0.1:9100/metrics
  a shell   docker exec -it ucode-prometheus-exporter-lab ash
  stop it   make lab-down
```

Ask it for our collector:

```bash
curl -s 'http://127.0.0.1:9100/metrics?collect[]=tasks' | grep '^node_tasks'
```

```
node_tasks_runnable 2
node_tasks 3255
```

Counted by our collector, in the exporter's jail, under procd. The numbers are your computer's: a container shares its host's kernel, and so its `/proc/loadavg`. Now open `http://127.0.0.1:8080/`, log in as `root` with no password, and go to **Services → Prometheus exporter**, tab **Collectors**: there is a row **Scheduler tasks**, with our help text and its package, `ucode-prometheus-exporter-tasks`. On **Status → Prometheus exporter** it is **OK**.

## 8. Clean up

Stop the lab:

```bash
make lab-down
```

and remove what we made, as this collector was practice:

```bash
rm src/prometheus_exporter/collectors/tasks.uc test/unit/prometheus_exporter/collectors/tasks_test.uc
git checkout openwrt/ucode-prometheus-exporter/Makefile
make docs-gen
```

---

## What we did

We wrote a collector that asks for one capability and writes two families, ran it on the command line, checked it keeps the collector contract, tested it with `test/context.uc`'s fakes, gave it a package, generated its reference, and saw it served by OpenWrt in its jail and listed in LuCI.

## Next

- [Collector interface](../reference/collector-interface.md): every field of `meta`, every capability, `out` and the Results.
- [Collector contract](../reference/collector-contract.md): what the exporter enforces of a collector, and what breaking a rule costs.
- [About nothing to observe](../explanation/nothing-to-observe.md): when a collector should answer `Result.none`.
- [How to capture fixtures from a device](../how-to/developer/fixtures.md): to test on what a real router answers.
- [How to package a collector](../how-to/developer/package-collector.md) and [How to run the benchmark](../how-to/developer/benchmarks.md).
