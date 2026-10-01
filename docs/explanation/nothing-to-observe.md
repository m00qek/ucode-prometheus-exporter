# About Nothing to Observe

A collector can succeed, fail, or have nothing to observe. The third case exists because a device is not broken for lacking what it was never meant to have. This page is about where the line runs, and why it is drawn there.

---

## The problem

Install the `-full` group on an access point without DSL, or on a router whose dnsmasq someone disabled, and a scrape runs the DSL and dnsmasq collectors all the same. Before, those collectors failed: `node_scrape_collector_success 0`, every scrape, and a line in the log, every scrape. An alert on failing collectors then fires on every device that does not have everything, and gets silenced; the log fills with what the device is, rather than what went wrong; and a real failure, dnsmasq crashing on a router that runs it, looks exactly like the device that has no dnsmasq.

## The line

A collector whose subject is not there has nothing to observe; one whose subject is there and cannot be read fails.

- **Nothing to observe:** hardware the device lacks (no radios, no DSL modem, no PoE switch), a kernel feature its kernel lacks (no connection tracking, IPv6 disabled), or a service someone disabled or never installed.
- **Failure:** a service that is enabled and does not answer, a program that fails or runs out of time, a call or a file that is there and cannot be read or parsed.

A collector with nothing to observe succeeds: `node_scrape_collector_success 1`. It writes no sample, and the scrape logs nothing of it. What it does write is `node_scrape_collector_observing{collector} 0`, which is 1 for every other collector.

The service line follows what someone decided. A service whose init script is disabled was turned off on purpose: watching it is pointless, and complaining about it is noise. A service whose init script is enabled is meant to run: if it does not answer, something is wrong, and that is a failure.

## Why a metric of its own

Both a device without radios and a device whose radios have no clients write no Wi-Fi station samples, and both succeed. They mean different things: one cannot have clients, the other has none right now. `node_scrape_collector_observing` tells them apart, so a dashboard can show "no radios" instead of "0 clients", and an alert can ask for observing collectors only.

Folding it into `node_scrape_collector_success` was the alternative. It would keep one metric, but it would make "succeeded" mean two things, and break the node_exporter convention that dashboards rely on: success is whether the collector worked, and it did.

## Asking whether a service is enabled

Whether a service is enabled is what rpcd's `rc` object says: `rc list` with the service's name answers whether its init script is enabled, or that there is none. rpcd reads `/etc/init.d` and `/etc/rc.d` itself, outside the exporter's jail, so the jail needs nothing more than the ubus socket it already has.

A collector asks `rc` only once its own source fails. A running dnsmasq answers its own ubus call, and the scrape asks nothing more; only a call that fails costs a second one, to learn whether the failure is a failure. The exception is mwan3, whose ubus object is rpcd's own plugin, which answers whether mwan3 runs or not: there, `rc` is asked first. When `rc` cannot say, the failure stands: a failure that might not be one is still reported.

timesync asks procd instead: whether the instance of busybox ntpd or chronyd runs. sysntpd's init script is enabled on every image and starts ntpd only when the system's NTP client is turned on, so its enabled script says nothing; its instance does.

## Where to see why

The reason is not a label of the metric: a reason that changes would start a new series. It is where a person looks: `service prometheus-exporter check`, the ubus object's `status` (`observing`, `reason`) and LuCI's status page, as "dnsmasq is disabled" or "no wireless radios".

Each collector's cases, and the reasons it gives, are in [Collectors](../reference/collectors.md#nothing-to-observe).

## Trade-offs

- **A disabled service is assumed to be on purpose.** A service someone disabled by mistake is reported as nothing to observe, not as a failure. The alternative, treating every installed service as expected, would bring back the noise this exists to remove.
- **Hardware that disappears is not a failure.** A USB modem unplugged, or a radio whose driver did not load, looks like a device without that hardware. `node_scrape_collector_observing` going from 1 to 0 is the signal to alert on, if that matters.
