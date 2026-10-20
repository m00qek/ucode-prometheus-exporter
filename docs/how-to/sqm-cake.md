# How to Monitor SQM and CAKE

The qdisc collector runs `tc` to read each network device's root queueing discipline (qdisc): what it sent, dropped and holds, with node_exporter's names. Where SQM shapes traffic with CAKE, the collector also reads CAKE's capacity and memory, and for each tin (CAKE's priority classes) its traffic, drops, ECN marks and delays.

## Prerequisites

- SQM is set up on the device, with `cake` as its queueing discipline (`sqm-scripts`, its `layer_cake.qos` or `piece_of_cake.qos`).

---

## 1. Install the qdisc collector

```sh
apk add ucode-prometheus-exporter-qdisc
```

It brings `tc`. The `-network` and `-full` groups also install it.

## 2. Find the devices SQM shapes

SQM makes CAKE the root qdisc of two devices: the interface it shapes, for upload, and an `ifb4<device>` it creates, for download:

```sh
prometheus-exporter scrape qdisc | grep '^node_qdisc_cake_capacity_estimate_bytes_per_second'
```

```
node_qdisc_cake_capacity_estimate_bytes_per_second{device="eth1"} 2500000
node_qdisc_cake_capacity_estimate_bytes_per_second{device="ifb4eth1"} 11875000
```

Here `eth1` is the WAN's upload, shaped to 20 Mbit/s, and `ifb4eth1` is its download, shaped to 95 Mbit/s.

## 3. Query it

Drops per second, by device and tin:

```promql
rate(node_qdisc_cake_tin_drops_total[5m])
```

The worst queueing delay of each tin, which SQM is there to keep low:

```promql
node_qdisc_cake_tin_peak_delay_seconds
```

The share of the shaped rate that the download uses (bytes per second over bytes per second):

```promql
rate(node_qdisc_bytes_total{device="ifb4eth1"}[5m])
  / on (device) node_qdisc_cake_capacity_estimate_bytes_per_second
```

ECN marks, which CAKE uses before it drops:

```promql
rate(node_qdisc_cake_tin_ecn_marks_total[5m])
```

Each tin is labeled by its index, as `tc` numbers them. A `besteffort` CAKE has only tin `0`. A `diffserv4` CAKE has tins `0` to `3`, from Bulk to Voice.

---

## What it leaves out

The collector reads only the root qdisc of each device. So it leaves out:

- SQM's `ingress` qdisc, which shapes nothing itself
- a multiqueue NIC's per-queue children
- HTB's leaves
- `noqueue`, the qdisc of bridges, VLANs and WireGuard, whose counters are always 0

A device that SQM does not shape still shows its default qdisc, `fq_codel`, with `node_qdisc_*` and no `node_qdisc_cake_*`.

[Metrics](../reference/metrics.md#qdisc) lists every family.
