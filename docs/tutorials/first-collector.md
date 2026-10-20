# Write Your First Collector

In this tutorial we will write a collector, `tasks`, that counts the kernel's tasks from `/proc/loadavg`. We will run it on the command line, test it, package it, and see OpenWrt serve it in the lab, in LuCI and at `/metrics`. Along the way we will meet the development environment: `make shell`, `make test`, the devkit's `with_collector`, `make docs-gen` and `make lab`.

It takes about half an hour, mostly waiting for builds. This collector is practice, so at the end we will remove what we made.

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

The first run builds the development image, based on OpenWrt's own, which takes a minute or two. Then the tests run, and the last lines say how they went:

```
Summary:

  1146 successes / 0 failures / 0 errors / 0 skipped / 0 ignored (49301 ms)
```

Your numbers will differ. What matters is `0 failures`.

## 2. Look at the source

Our collector will read the fourth field of `/proc/loadavg`. Let's look at the file in the development image:

```bash
make shell
```

```sh
cat /proc/loadavg
```

```
0.72 0.61 0.97 2/3199 81234
```

The fourth field, `2/3199`, gives the tasks that are runnable now and the tasks that exist. Leave the shell with `exit`.

## 3. Write the collector

Create `src/prometheus/collectors/tasks.uc`:

```js
'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

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

Notice four things:

- The collector imports one module, `prometheus.exporter`, the collector API. Everything it uses from the exporter comes from there.
- `meta.needs` asks for `fs`, and `collect` reads the file through `deps.fs`, not by importing `fs`. A collector only gets what it asks for, and the exporter refuses a collector that imports anything else.
- `out.gauge` declares a family, and returns a function that records a sample.
- `collect` returns a Result: `Result.ok()` when it worked, or `Result.err()` with a code when it did not.

## 4. Run it

Back in the development image:

```bash
make shell
```

```sh
ucode -L /exporter/src files/usr/bin/prometheus-exporter scrape -d src/prometheus/collectors tasks
```

This runs the exporter's own command from the source tree. It loads the collectors from `src/`, and runs only ours. It prints a scrape:

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

Our two families come first. Then come the metrics every scrape writes about each collector that ran: ours succeeded. The version is `dev`, since it runs from a source tree.

Now let the exporter check our module against the rules it holds every collector to. This is the check you would run before anyone installs a collector:

```sh
ucode -L /exporter/src files/usr/bin/prometheus-exporter collector check src/prometheus/collectors/tasks.uc
```

```
ok   strict mode: 'use strict' first
ok   imports: prometheus.exporter alone
ok   top level: declarations alone
ok   load: 0.001 s, of at most 5 s
ok   meta: tasks (Scheduler tasks), needs fs, budget 5 s, max_samples 20000
ok   run: 0.000 s, 2 samples in 2 families
ok   families: node_tasks_runnable node_tasks
ok   exposition: valid text, each series once
```

Every line is `ok`. Our collector:

- imports the API alone,
- only declares at its top level,
- loads quickly,
- has a valid `meta`,
- ran in its own process, well within its budget, and
- wrote two families that no installed collector writes.

If it had looped, or written `node_load1`, a line would say `FAIL`, and why. Leave the shell with `exit`.

## 5. Test it

Tests run the collector the way a scrape does, with fakes in place of the system. The devkit's `with_collector` provides them. It is the same tool that tests a collector in another package. Create `test/unit/prometheus/collectors/tasks_test.uc`:

```js
'use strict';

import { describe, it, assert } from 'utest';
import { with_collector } from 'prometheus.exporter.devkit.collector';
import * as tasks from 'prometheus.collectors.tasks';

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

`with_collector` hands the collector an `fs` that answers from `data`, and runs it. It gives us what the collector wrote: `r.result`, `r.lines`, and `r.logs`, which is what the scrape would log. The second test hands the collector a file that cannot be read.

`with_collector` also behaves as the exporter's jail would. If our collector read a file outside `/proc` and `/sys` without declaring it, the test would fail, and say so. Run only these tests:

```bash
make unit MODULES=test/unit/prometheus/collectors/tasks_test.uc
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

`test/integration/collectors_test.uc` checks that the repository gives every collector what it needs, such as a package and a reference entry. The documentation's generator also finds a collector in no package. Ours has no package yet. Open `openwrt/ucode-prometheus-exporter/Makefile`, find the `Collector` lines, and add ours after `sockstat`'s:

```makefile
$(eval $(call Collector,tasks,tasks,scheduler tasks,))
```

That makes a package, `ucode-prometheus-exporter-tasks`. Then regenerate the reference pages, which are written from the code:

```bash
make docs-gen
```

```
wrote docs/reference/collectors.md
wrote docs/reference/error-codes.md
wrote docs/reference/metrics.md
```

Open `docs/reference/metrics.md` and find the `tasks` section. Our two families are there, with their type and help. The generator ran our collector on the captures of real routers in `test/fixtures/`, and wrote down what it produced. Now run the tests again:

```bash
make test
```

The summary says `0 failures` again.

## 7. See it on OpenWrt

The lab is OpenWrt under procd, in a container, with every package installed. Start it:

```bash
make lab
```

It builds the packages with OpenWrt's SDK, which takes a few minutes the first time. Then it boots OpenWrt and installs them. It ends with:

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

Our collector counted these, in the exporter's jail, under procd. The numbers are your computer's: a container shares its host's kernel, and so its `/proc/loadavg`.

Now open `http://127.0.0.1:8080/` and log in as `root` with no password. Go to **Services → Prometheus exporter**, tab **Collectors**. You see a row **Scheduler tasks**, with our help text and its package, `ucode-prometheus-exporter-tasks`. On **Status → Prometheus exporter**, it shows **OK**.

## 8. Clean up

Stop the lab:

```bash
make lab-down
```

Then remove what we made, since this collector was practice:

```bash
rm src/prometheus/collectors/tasks.uc test/unit/prometheus/collectors/tasks_test.uc
git checkout openwrt/ucode-prometheus-exporter/Makefile
make docs-gen
```

---

## What we did

We wrote a collector that asks for one capability and writes two families. We ran it on the command line, checked that it keeps the collector contract, and tested it with the devkit's fakes. We gave it a package, generated its reference, and saw OpenWrt serve it in its jail and list it in LuCI.

## Next

- [Collector interface](../reference/collector-interface.md): every field of `meta`, every capability, `out` and the Results.
- [Collector contract](../reference/collector-contract.md): what the exporter enforces on a collector, and what breaking a rule costs.
- [About nothing to observe](../explanation/nothing-to-observe.md): when a collector should answer `Result.none`.
- [How to capture fixtures from a device](../how-to/developer/fixtures.md): to test on what a real router answers.
- [How to package a collector](../how-to/developer/package-collector.md) and [How to run the benchmark](../how-to/developer/benchmarks.md).
- [How to write a collector in your own package](../how-to/collector-package.md): the same, outside the exporter's tree.
