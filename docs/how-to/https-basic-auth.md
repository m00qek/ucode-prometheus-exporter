# How to Serve HTTPS with Basic Auth

Have every scrape log in with a user and password, over TLS. The exporter takes basic auth over HTTPS only: set the certificate and key with it, or the configuration is refused.

## Prerequisites

- A TLS library for uhttpd: `ls /lib/libustream-ssl.so` finds it. Without it, install one, as `apk add libustream-mbedtls`.
- A certificate and its key, for the name Prometheus reaches the device by, each a file of at most 64 KiB under `/etc/ssl`, `/etc/acme` or `/etc/prometheus-exporter`, or uhttpd's own `/etc/uhttpd.*`: the service copies no other (see [About the security model](../explanation/security.md#not-root)). To make a self-signed one for `router.lan`:

    ```sh
    mkdir -p /etc/prometheus-exporter
    px5g selfsigned -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout /etc/prometheus-exporter/tls.key -out /etc/prometheus-exporter/tls.crt \
        -subj /CN=router.lan -addext subjectAltName=DNS:router.lan
    ```

    uhttpd's own, `/etc/uhttpd.crt` and `/etc/uhttpd.key`, also serve, but they name `OpenWrt` unless uhttpd's config says otherwise, and the certificate is DER: convert it to PEM for Prometheus (`openssl x509 -inform der -in uhttpd.crt -out openwrt.crt`).

---

## 1. Save the password's hash

Use a long random password, as a scraper's can be. The configuration holds its crypt hash, never the password, in a config of its own, `/etc/config/prometheus-exporter-auth`, apart from the rest, which LuCI's settings page may read. Have the ubus object hash the password and save the hash there, so the password is on no command line of the device:

```sh
ubus call prometheus-exporter set_password '{"password":"…"}'
```

```
{
	"saved": true
}
```

In LuCI, **Change password…** on the **HTTPS & login** tab does the same, apart from Save & Apply: see [How to use the LuCI app](luci.md#change-basic-auths-password).

Or save a hash yourself, from `prometheus-exporter hash-password` (the command line's package, `ucode-prometheus-exporter-cli`), which reads the password without echoing it:

```sh
uci set prometheus-exporter-auth.main.auth_password="$(prometheus-exporter hash-password)"
uci commit prometheus-exporter-auth
```

A hash made elsewhere must be `$1$` (as `uhttpd -m <password>` prints), or `$5$` or `$6$` of at most 2000 rounds, as `mkpasswd -m sha-512 -R 1000` makes. `openssl passwd -6` makes hashes of 5000 rounds, which are refused. Why: [Performance on small routers](../explanation/performance.md#basic-auth). Set one by hand in single quotes: the shell would read its `$` otherwise.

A DES-crypt hash is not taken: its 13 characters could be a plain password, which uhttpd compares as text when it does not start with `$`. Nor is bcrypt, which ucode cannot compute in the time of a scrape. A hash made elsewhere must write `rounds=` as musl writes it back, without a leading zero and in range, or no password matches it.

## 2. Set the user, and HTTPS

```sh
uci set prometheus-exporter.main.auth_user='prometheus'
uci set prometheus-exporter.main.cert='/etc/prometheus-exporter/tls.crt'
uci set prometheus-exporter.main.key='/etc/prometheus-exporter/tls.key'
uci commit prometheus-exporter
service prometheus-exporter reload
```

Basic auth is on while `auth_user` is set. If the reload refuses the configuration, `logread -e prometheus-exporter` says why: a user without a saved hash, a hash it does not take, no `cert` and `key`, or one of them elsewhere than those directories (`TLS_PATH`), or not a regular file of at most 64 KiB, or a link out of them (`TLS_FILE`).

## 3. Check it

```sh
service prometheus-exporter status
```

```
running
listening on https://192.168.1.1:9100/metrics, basic auth, gzip when asked, serving 16 collectors
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

Copy the router's certificate (`/etc/prometheus-exporter/tls.crt`), not its key, to the Prometheus host as `ca_file`.

---

## Renew the certificate

The service's jail holds the certificate and key it started with. After writing new ones at the same paths, reload the service, which restarts it with them:

```sh
service prometheus-exporter reload
```

A tool that renews certificates on its own, as acme does, runs that from its hook. OpenWrt's acme keeps them in `/etc/ssl/acme`, and acme.sh's own in `/etc/acme`, where `cert` and `key` may point, its links too. Until then the old certificate is served.

## Turn it off

```sh
uci delete prometheus-exporter.main.auth_user
uci commit prometheus-exporter
ubus call prometheus-exporter set_password '{"password":""}'
service prometheus-exporter reload
```

The empty password removes the saved hash; without a user it would be unused all the same. In LuCI: empty **Basic auth user**, **Save & Apply**, then **Remove password**.

With `cert` and `key` left, it serves HTTPS without a login; delete them too for HTTP.

## See also

- [HTTP endpoint](../reference/http.md#basic-auth): the replies.
- [About the security model](../explanation/security.md): why HTTPS only, and why the handler checks the password itself.
- In LuCI: the **HTTPS & login** tab's **Change password…** hashes the password for you, and saves the hash at once. See [How to use the LuCI app](luci.md#change-basic-auths-password).
