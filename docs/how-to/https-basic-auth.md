# How to Serve HTTPS with Basic Auth

Have every scrape log in with a user and password, over TLS. The exporter takes basic auth over HTTPS only: set the certificate and key with it, or the configuration is refused.

## Prerequisites

- A TLS library for uhttpd: `ls /lib/libustream-ssl.so` finds it. Without it, install one, as `apk add libustream-mbedtls`.
- A certificate and its key, for the name Prometheus reaches the device by. To make a self-signed one for `router.lan`:

    ```sh
    px5g selfsigned -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout /etc/prometheus-exporter.key -out /etc/prometheus-exporter.crt \
        -subj /CN=router.lan -addext subjectAltName=DNS:router.lan
    ```

    uhttpd's own, `/etc/uhttpd.crt` and `/etc/uhttpd.key`, also serve, but they name `OpenWrt` unless uhttpd's config says otherwise, and the certificate is DER: convert it to PEM for Prometheus (`openssl x509 -inform der -in uhttpd.crt -out openwrt.crt`).

---

## 1. Hash the password

Use a long random password, as a scraper's can be. Have the ubus object hash it, so the password is on no command line of the device:

```sh
ubus call prometheus-exporter hash_password '{"password":"…"}'
```

```
{
	"hash": "$6$rounds=1000$IgztncwtDxRNxtVD$emPK…"
}
```

To use a hash made elsewhere, it must be `$1$` (as `uhttpd -m <password>` prints), or `$5$` or `$6$` of at most 2000 rounds, as `mkpasswd -m sha-512 -R 1000` makes. `openssl passwd -6` makes hashes of 5000 rounds, which are refused. Why: [Performance on small routers](../explanation/performance.md#basic-auth).

## 2. Set it

```sh
uci set prometheus-exporter.main.auth_user='prometheus'
uci set prometheus-exporter.main.auth_password='$6$rounds=1000$IgztncwtDxRNxtVD$emPK…'
uci set prometheus-exporter.main.cert='/etc/prometheus-exporter.crt'
uci set prometheus-exporter.main.key='/etc/prometheus-exporter.key'
uci commit prometheus-exporter
service prometheus-exporter reload
```

Keep the single quotes around the hash: the shell would read its `$` otherwise.

If the reload refuses the configuration, `logread -e prometheus-exporter` says why: a user without a hash, a hash it does not take, or no `cert` and `key`.

## 3. Check it

```sh
service prometheus-exporter status
```

```
running
listening on https://192.168.1.1:9100/metrics, basic auth, gzip when asked, serving 15 collectors
```

From the machine that scrapes:

```sh
curl -sk -o /dev/null -w '%{http_code}\n' https://router.lan:9100/metrics
curl -sk -u prometheus:'…' https://router.lan:9100/metrics | head
```

The first is `401`; the second is the scrape.

## 4. Scrape it

In Prometheus, and in vmagent, which takes the same `scrape_configs`:

```yaml
scrape_configs:
  - job_name: openwrt
    scheme: https
    basic_auth:
      username: prometheus
      password_file: /etc/prometheus/openwrt.password
    tls_config:
      ca_file: /etc/prometheus/openwrt.crt   # the router's certificate, self-signed
      server_name: router.lan                # a name the certificate holds
      # insecure_skip_verify: true           # or: no check of the certificate at all
    static_configs:
      - targets: [ 'router.lan:9100' ]
```

Copy the router's certificate (`/etc/prometheus-exporter.crt`), not its key, to the Prometheus host as `ca_file`.

---

## Turn it off

```sh
uci delete prometheus-exporter.main.auth_user
uci delete prometheus-exporter.main.auth_password
uci commit prometheus-exporter
service prometheus-exporter reload
```

With `cert` and `key` left, it serves HTTPS without a login; delete them too for HTTP.

## See also

- [HTTP endpoint](../reference/http.md#basic-auth): the replies.
- [About the security model](../explanation/security.md): why HTTPS only, and why the handler checks the password itself.
- In LuCI: the Exporter tab's TLS and basic auth fields hash the password for you. See [How to use the LuCI app](luci.md).
