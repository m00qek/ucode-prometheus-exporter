# How to Listen on the LAN

By default the exporter listens on `loopback`: only programs on the device reach it. To scrape it from another machine, have it listen on an interface that machine reaches.

---

## 1. Choose the interface

Use the name of a logical interface, as `/etc/config/network` and LuCI name them (`lan`), not of a device (`br-lan`). `ubus call prometheus-exporter interfaces` lists them.

`*` listens on every address of the device, the WAN's included. Prefer one interface.

## 2. Set it

```sh
uci set prometheus-exporter.main.listen_interface=lan
uci commit prometheus-exporter
service prometheus-exporter reload
```

To change the port too, set `listen_port`.

The service listens on every IPv4 and IPv6 address of the interface. While the interface has no address, it does not start: it logs `deferring start until listen interface lan becomes ready` and starts once it comes up, and again whenever it goes down and up.

## 3. Check it

On the device:

```sh
service prometheus-exporter status
```

```
running
listening on http://192.168.1.1:9100/metrics, http://[fd00:ab:cd::1]:9100/metrics, gzip when asked, serving 16 collectors
```

From the machine that will scrape it:

```sh
curl -s http://192.168.1.1:9100/metrics | head
```

## If it does not answer

- The firewall must accept input on the port from that zone. OpenWrt's default `lan` zone accepts input; another zone may need a rule:

    ```sh
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-Prometheus'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].dest_port='9100'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
    service firewall reload
    ```

    Never open it from `wan`: the metrics name your devices, addresses and clients.

- `status` does not say `running`: the interface has no address yet, and the service waits for it. Check `ifstatus lan`.

## Keep it to the scrapers

Every request to `/metrics` is a scrape, which costs the router its CPU for a while, and with basic auth a password's check, which costs more; uhttpd runs 3 at once and has the rest wait (see [HTTP endpoint](../reference/http.md#connections)). So whoever reaches the port can delay the scrapes Prometheus makes. Let only the scrapers reach it: a rule that accepts the port from the Prometheus host alone, before the zone's own policy, and drops it for the rest of the zone:

```sh
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Prometheus'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].src_ip='192.168.1.10'
uci set firewall.@rule[-1].dest_port='9100'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'
uci add firewall rule
uci set firewall.@rule[-1].name='Deny-Prometheus-others'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_port='9100'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='REJECT'
uci commit firewall
service firewall reload
```

with the Prometheus host's address for `192.168.1.10`. fw4 matches rules in order, so the first lets it in and the second keeps the rest of the LAN out.

---

To ask a password of every scrape, and send it over TLS, see [How to serve HTTPS with basic auth](https-basic-auth.md).
