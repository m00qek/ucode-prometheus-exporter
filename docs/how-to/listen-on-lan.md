# How to Listen on the LAN

By default, the exporter listens on `loopback`, so only programs on the device reach it. To scrape it from another machine, make it listen on an interface that machine reaches.

---

## 1. Choose the interface

Use the name of a logical interface, as `/etc/config/network` and LuCI name it (`lan`), not the name of a device (`br-lan`). LuCI's **Listen on** lists them, and so does `ubus call prometheus-exporter interfaces`.

`*`, which LuCI shows as *Every address*, listens on every address of the device, including the WAN's. Prefer one interface.

## 2. Set it

=== "Browser (LuCI)"

    1. Open **Services → Prometheus exporter**, tab **General**.
    2. Pick the interface in **Listen on**, such as `lan`. To change the port too, set **Port**.
    3. Press **Save & Apply**.

=== "Terminal (SSH)"

    ```sh
    uci set prometheus-exporter.main.listen_interface=lan
    uci commit prometheus-exporter
    service prometheus-exporter reload
    ```

    To change the port too, set `listen_port`.

The service listens on every IPv4 and IPv6 address of the interface. While the interface has no address, the service does not start. It logs `deferring start until listen interface lan becomes ready`, and starts once the interface comes up. It restarts whenever the interface goes down and up again.

## 3. Check it

On the device:

=== "Browser (LuCI)"

    Open **Status → Prometheus exporter**. Under **Service**, **Metrics** lists each address the exporter serves, such as `http://192.168.1.1:9100/metrics`.

=== "Terminal (SSH)"

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

- The firewall must accept input on the port from that zone. OpenWrt's default `lan` zone accepts input. Another zone may need a rule:

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

    Never open the port from `wan`: the metrics name your devices, addresses and clients.

- If `status` does not say `running` (in LuCI, **State** is not **Running**), the interface has no address yet, and the service is waiting for one. Check `ifstatus lan`.

## Keep it to the scrapers

Every request to `/metrics` is a scrape, which keeps the router's CPU busy for a while. With basic auth, each request also costs a password check, which is more expensive. uhttpd runs 3 requests at once and makes the rest wait (see [HTTP endpoint](../reference/http.md#connections)). So anyone who reaches the port can delay Prometheus's scrapes.

Let only the scrapers reach the port. Add a rule that accepts the port from the Prometheus host alone, before the zone's own policy, and a rule that rejects it for the rest of the zone:

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

Replace `192.168.1.10` with the Prometheus host's address. fw4 matches rules in order, so the first rule lets the Prometheus host in and the second keeps the rest of the LAN out.

---

To require a password for every scrape, sent over TLS, see [How to serve HTTPS with basic auth](https-basic-auth.md).
