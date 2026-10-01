'use strict';

// Traffic control's queueing disciplines: what SQM's CAKE (or fq_codel, or
// whatever a device's root qdisc is) sent, dropped and holds, from
// `tc -s -j qdisc show`. ucode's rtnl on OpenWrt 25.12 has RTM_GETQDISC's
// constants but does not decode a qdisc's statistics (TCA_STATS2, TCA_XSTATS),
// so iproute2's tc reads them, as JSON.
//
// The families are node_exporter's (collector/qdisc_linux.go), with its names,
// help and labels, device and kind, for the root qdisc of each device, as it
// reports them: one series per device. The rest of the tree (mq's per-queue
// children, SQM's ingress qdisc, which shapes nothing itself, HTB's leaves) is
// left out, and so is noqueue, the qdisc of a device without a queue (a bridge,
// a VLAN, WireGuard), whose counters are always 0. A device without a qdisc of
// its own has the kernel's default (fq_codel on OpenWrt, mq over it on a
// multiqueue NIC), which is reported as any other.
//
// A root CAKE qdisc also has node_qdisc_cake_*: its capacity estimate and
// memory, and per tin (labeled by its index, as tc numbers them: a
// besteffort CAKE has tin 0 only, diffserv4 tins 0 to 3, Bulk to Voice) its
// traffic, drops, ECN marks, ACKs dropped, delays and flows. No exporter of
// CAKE's statistics is widely used: the names follow the conventions, from
// tc's JSON keys (tc/q_cake.c), in base units.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

export const meta = {
	name: 'qdisc',
	title: 'Traffic control queues',
	help: 'Statistics of each network device\'s root queueing discipline, and CAKE\'s per tin, from tc.',
	needs: [ 'exec' ],
	commands: [ 'tc' ],
};

const TC = [ 'tc', '-s', '-j', 'qdisc', 'show' ];

// CAKE's delays are in microseconds.
const US = 1000000.0;

function families(out) {
	return {
		bytes: out.counter('node_qdisc_bytes_total', 'Number of bytes sent.'),
		packets: out.counter('node_qdisc_packets_total', 'Number of packets sent.'),
		drops: out.counter('node_qdisc_drops_total', 'Number of packets dropped.'),
		requeues: out.counter('node_qdisc_requeues_total', 'Number of packets dequeued, not transmitted, and requeued.'),
		overlimits: out.counter('node_qdisc_overlimits_total', 'Number of overlimit packets.'),
		qlen: out.gauge('node_qdisc_current_queue_length', 'Number of packets currently in queue to be sent.'),
		backlog: out.gauge('node_qdisc_backlog', 'Number of bytes currently in queue to be sent.'),
	};
}

function cake_families(out) {
	return {
		capacity: out.gauge('node_qdisc_cake_capacity_estimate_bytes_per_second', 'The rate CAKE shapes to, in bytes per second: its bandwidth, or what autorate-ingress estimates.'),
		memory_used: out.gauge('node_qdisc_cake_memory_used_bytes', 'Memory CAKE\'s queues use, in bytes.'),
		memory_limit: out.gauge('node_qdisc_cake_memory_limit_bytes', 'Memory CAKE\'s queues may use, in bytes.'),
		threshold: out.gauge('node_qdisc_cake_tin_threshold_rate_bytes_per_second', 'The rate a CAKE tin is shaped to, in bytes per second.'),
		bytes: out.counter('node_qdisc_cake_tin_bytes_total', 'Bytes a CAKE tin sent.'),
		packets: out.counter('node_qdisc_cake_tin_packets_total', 'Packets a CAKE tin sent.'),
		drops: out.counter('node_qdisc_cake_tin_drops_total', 'Packets a CAKE tin dropped.'),
		ecn_marks: out.counter('node_qdisc_cake_tin_ecn_marks_total', 'Packets a CAKE tin marked with ECN instead of dropping them.'),
		ack_drops: out.counter('node_qdisc_cake_tin_ack_drops_total', 'ACKs a CAKE tin\'s ACK filter dropped.'),
		backlog: out.gauge('node_qdisc_cake_tin_backlog_bytes', 'Bytes queued in a CAKE tin.'),
		peak_delay: out.gauge('node_qdisc_cake_tin_peak_delay_seconds', 'Peak queueing delay in a CAKE tin, in seconds.'),
		avg_delay: out.gauge('node_qdisc_cake_tin_average_delay_seconds', 'Average queueing delay in a CAKE tin, in seconds.'),
		base_delay: out.gauge('node_qdisc_cake_tin_base_delay_seconds', 'Queueing delay of a CAKE tin\'s sparse flows, in seconds.'),
		sparse_flows: out.gauge('node_qdisc_cake_tin_sparse_flows', 'Sparse flows in a CAKE tin.'),
		bulk_flows: out.gauge('node_qdisc_cake_tin_bulk_flows', 'Bulk flows in a CAKE tin.'),
		unresponsive_flows: out.gauge('node_qdisc_cake_tin_unresponsive_flows', 'Flows in a CAKE tin that do not respond to congestion signals.'),
	};
}

function us(v) {
	return type(v) in [ 'int', 'double' ] ? v / US : null;
}

// A CAKE qdisc's own samples, and its tins'.
function cake(c, out, device, q) {
	let labels = out.labels({ device });

	c.capacity(labels, q.capacity_estimate);
	c.memory_used(labels, q.memory_used);
	c.memory_limit(labels, q.memory_limit);

	for (let i, t in (type(q.tins) == 'array' ? q.tins : [])) {
		if (type(t) != 'object')
			continue;

		let tin = out.labels({ device, tin: i });

		c.threshold(tin, t.threshold_rate);
		c.bytes(tin, t.sent_bytes);
		c.packets(tin, t.sent_packets);
		c.drops(tin, t.drops);
		c.ecn_marks(tin, t.ecn_mark);
		c.ack_drops(tin, t.ack_drops);
		c.backlog(tin, t.backlog_bytes);
		c.peak_delay(tin, us(t.peak_delay_us));
		c.avg_delay(tin, us(t.avg_delay_us));
		c.base_delay(tin, us(t.base_delay_us));
		c.sparse_flows(tin, t.sparse_flows);
		c.bulk_flows(tin, t.bulk_flows);
		c.unresponsive_flows(tin, t.unresponsive_flows);
	}
}

export function collect(deps, out) {
	let res = deps.exec.run(TC);

	if (!res.ok)
		return res;

	let list;
	try {
		list = json(res.data);
	} catch (e) {
		return Result.err(errors.SOURCE_INVALID, `tc -s -j qdisc show: ${e.message}`);
	}

	if (type(list) != 'array')
		return Result.err(errors.SOURCE_INVALID, 'tc -s -j qdisc show: not a list of qdiscs');

	let f = null, c = null;

	for (let q in list) {
		if (type(q) != 'object' || q.root !== true || type(q.dev) != 'string' || type(q.kind) != 'string' || q.kind == 'noqueue')
			continue;

		f ??= families(out);

		let labels = out.labels({ device: q.dev, kind: q.kind });

		f.bytes(labels, q.bytes);
		f.packets(labels, q.packets);
		f.drops(labels, q.drops);
		f.requeues(labels, q.requeues);
		f.overlimits(labels, q.overlimits);
		f.qlen(labels, q.qlen);
		f.backlog(labels, q.backlog);

		if (q.kind == 'cake') {
			c ??= cake_families(out);
			cake(c, out, q.dev, q);
		}
	}

	return Result.ok();
};
