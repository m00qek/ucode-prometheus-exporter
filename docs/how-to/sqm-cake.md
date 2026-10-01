# How to Monitor SQM and CAKE

The qdisc collector reads each network device's root queueing discipline with `tc`: what it sent, dropped and holds, with node_exporter's names. Where SQM shapes with CAKE, it also reads CAKE's capacity, memory and, per tin, its traffic, drops, ECN marks and delays.

## Prerequisites

- SQM is set up on the device, with `cake` as its queueing discipline (`sqm-scripts`, its `layer_cake.qos` or `piece_of_cake.qos`).

---

## 1. Install the qdisc collector

```sh
apk add ucode-prometheus-exporter-qdisc
```

It brings `tc`. It is in the `-network` and `-full` groups too.

## 2. Find the devices SQM shapes

SQM puts CAKE as the root qdisc of the interface it shapes, for upload, and of an `ifb4<device>` it makes for download:

```sh
prometheus-exporter qdisc | grep '^node_qdisc_cake_capacity_estimate_bytes_per_second'
```

```
node_qdisc_cake_capacity_estimate_bytes_per_second{device="eth1"} 2500000
node_qdisc_cake_capacity_estimate_bytes_per_second{device="ifb4eth1"} 11875000
```

Here `eth1` is the WAN's upload, shaped to 20 Mbit/s, and `ifb4eth1` its download, to 95 Mbit/s.

## 3. Query it

Drops per second, by device and tin:

```promql
rate(node_qdisc_cake_tin_drops_total[5m])
```

The worst queueing delay of each tin, which SQM is there to keep low:

```promql
node_qdisc_cake_tin_peak_delay_seconds
```

How much of the shaped rate the download uses, in bytes per second over bytes per second:

```promql
rate(node_qdisc_bytes_total{device="ifb4eth1"}[5m])
  / on (device) node_qdisc_cake_capacity_estimate_bytes_per_second
```

ECN marks, which CAKE uses before it drops:

```promql
rate(node_qdisc_cake_tin_ecn_marks_total[5m])
```

A tin is labeled by its index, as `tc` numbers them: a `besteffort` CAKE has tin `0` only, `diffserv4` tins `0` to `3`, Bulk to Voice.

---

## What it leaves out

Only the root qdisc of each device is read: SQM's `ingress` qdisc, which shapes nothing itself, a multiqueue NIC's per-queue children and HTB's leaves are left out, and so is `noqueue`, the qdisc of bridges, VLANs and WireGuard, whose counters are always 0. A device SQM does not shape still shows its default qdisc, `fq_codel`, with `node_qdisc_*` and no `node_qdisc_cake_*`.

Every family is in [Metrics](../reference/metrics.md#qdisc).
