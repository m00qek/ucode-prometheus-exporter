# Metric names

This exporter replaces OpenWrt's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua` (it conflicts with both, and takes over their settings), but not their metric names. Where the Prometheus [node_exporter](https://github.com/prometheus/node_exporter) has an equivalent metric, this exporter uses node_exporter's name, type, labels and help text, so dashboards made for it (such as Grafana's "Node Exporter Full") work. Elsewhere, the names follow the [Prometheus naming conventions](https://prometheus.io/docs/practices/naming/):

- base units in the name (`_seconds`, `_bytes`, `_hertz`, `_bits_per_second`, `_celsius`, `_ratio`, and `_dbm` or `_db` for radio levels);
- `_total` on counters only, and every counter ends in `_total`;
- a metric of labels only is `<name>_info` with the value 1;
- a boolean is a gauge of 0 or 1, an enumeration one series per state with the value 1 or 0;
- snake_case metric and label names, and no unit on a unitless value.

Each service keeps its own prefix (`dnsmasq_`, `dsl_`, `wireguard_`, `mwan3_`, `hostapd_`, `dawn_`, `bmx7_`, `realtek_poe_`, `ubnt_`, `modemmanager_`, `unbound_`, `nft_counter_`), and OpenWrt's own metrics are `node_openwrt_*`. Where a widely used standalone exporter exists for a service and its names follow the conventions, this exporter uses them too: see [Standalone exporters](#standalone-exporters).

There is no option to get the old names back. The table below lists, per collector, every family whose name, type, labels or unit changed, from the names of the exporters this one replaces to this one's; a family not listed has kept its name. In the Type column, `a → b` is a type that changed.

## Base collectors

| Before | After | Type | Why |
|---|---|---|---|
| `node_cpu_seconds_total{cpu="cpu0",mode}` | `node_cpu_seconds_total{cpu="0",mode}` | counter | node_exporter labels the CPU by its number. |
| `node_cpu_seconds_total{mode="guest"\|"guest_nice"}` | `node_cpu_guest_seconds_total{mode="user"\|"nice"}` | counter | node_exporter keeps guest time apart (the kernel counts it in user and nice as well). |
| `node_procs_running_total` | `node_procs_running` | gauge | A gauge has no `_total`; node_exporter's name. |
| `node_procs_blocked_total` | `node_procs_blocked` | gauge | A gauge has no `_total`; node_exporter's name. |
| `node_memory_<Field>_bytes` of a field without a unit (`HugePages_Total`, `HugePages_Free`, `HugePages_Rsvd`, `HugePages_Surp`) | `node_memory_<Field>` | gauge | Page counts, not bytes: node_exporter names them without a unit. Fields in kB keep `_bytes`. |
| `node_selinux_enabled`, `node_selinux_current_mode` | unchanged | gauge | node_exporter's help texts. |
| — | `node_network_receive_nohandler_total{device}` | counter | New: node_exporter's netdev collector reads it from netlink too. |
| — | `node_network_up{device}` | gauge | New: node_exporter's, 1 when the operstate is `up`. |
| `node_network_info{device,address,broadcast,duplex,operstate,ifalias}` | `node_network_info{device,address,broadcast,duplex,operstate,adminstate,ifalias}` | gauge | node_exporter's labels: `adminstate` is `up` or `down` by the IFF_UP flag. |
| `node_network_speed_bytes` (left out at 0 Mb/s) | `node_network_speed_bytes` (0 Mb/s is 0) | gauge | As node_exporter, which leaves out only an unknown speed (-1). |

conntrack, entropy, filefd, loadavg, time and uname already had node_exporter's names.

## Network collectors

| Before | After | Type | Why |
|---|---|---|---|
| `node_netstat_<Section>_<Field>` (from `/proc/net/netstat` and `/proc/net/snmp`) | `node_netstat_<Section>_<Field>` | gauge → untyped | node_exporter's type, and its help text `Statistic <Section><Field>.` |
| `snmp6_<Name>{device="all"}` (from `/proc/net/snmp6`) | `node_netstat_<Protocol>_<Field>` (`node_netstat_Ip6_InReceives`, `node_netstat_Icmp6_*`, `node_netstat_Udp6_*`, `node_netstat_UdpLite6_*`) | counter → untyped | node_exporter's netstat collector reads `/proc/net/snmp6`; written by the netstat collector, not snmp6. |
| `snmp6_<Name>{device}` (from `/proc/net/dev_snmp6/<device>`) | `node_snmp6_<Protocol>_<Field>_total{device}` | counter | node_exporter has no per-device IPv6 statistics: the `node_` namespace, the name split as netstat splits it, and `_total` on a counter. |
| `snmp6_ifIndex{device}` | `node_snmp6_ifindex{device}` | counter → gauge | An interface index is not a count. |
| `node_ethtool_<stat>` | `node_ethtool_<stat>` | untyped | node_exporter's naming: `rx` and `tx` are spelled out only between underscores (`rx0_x` stays `rx0_x`), a statistic is named `Network interface <stat>`, a device's statistics are written sorted by name, and every statistic of a name two of them make is left out (before, the first was kept). Only the links a device backs (`/sys/class/net/<link>/device`) are asked: not bridges, VLANs, WireGuard, ifb or veth, whose drivers have no statistics or repeat netdev's. |
| `node_ethtool_{received,transmitted}_*_total` (7 common statistics) | unchanged | untyped | node_exporter's help texts (`Network interface bytes received`, ...). |
| `node_nat_traffic{src,dst}` | `node_nat_traffic_bytes{src,dst}` | gauge | Base unit in the name. A gauge: a sum over the connections there are now. |
| `nft_counter_packets` | `nft_counter_packets_total` | counter | A counter ends in `_total`. |
| `nft_counter_bytes` | `nft_counter_bytes_total` | counter | A counter ends in `_total`. |

## Wireless collectors

wifi and wifi_stations write node_exporter's wifi collector families, with its help texts and its labels: `device` (was `ifname`) and `mac_address` (was `mac`). wifi adds a `radio` label to every family.

| Before | After | Type | Why |
|---|---|---|---|
| `wifi_radio_info{radio,htmode,channel,country}` | `node_wifi_radio_info{radio,htmode,channel,country}` | gauge | node_exporter's `node_wifi_` namespace. |
| — | `node_wifi_interface_frequency_hertz{radio,device}` | gauge | New: node_exporter's. |
| `wifi_network_info{radio,ifname,ssid,bssid,mode}` | `node_wifi_network_info{radio,device,ssid,bssid,mode}` | gauge | `node_wifi_` namespace, node_exporter's `device` label. |
| `wifi_network_quality` (percent) | `node_wifi_network_quality_ratio` | gauge | A ratio, not a percentage. |
| `wifi_network_bitrate` (kbit/s) | `node_wifi_network_transmit_bits_per_second` | gauge | Base unit. |
| `wifi_network_noise_dbm` | `node_wifi_network_noise_dbm` | gauge | `node_wifi_` namespace. |
| `wifi_network_signal_dbm` | `node_wifi_network_signal_dbm` | gauge | `node_wifi_` namespace. |
| `wifi_stations_total{radio,ifname}` (wifi), `wifi_stations{ifname}` (wifi_stations) | `node_wifi_stations{[radio,]device}` | counter → gauge (wifi) | The stations associated now are not a counter. |
| — | `node_wifi_station_connected_seconds_total` | counter | New: node_exporter's. |
| `wifi_station_inactive_milliseconds` | `node_wifi_station_inactive_seconds` | gauge | node_exporter's name, in seconds. |
| `wifi_station_receive_kilobits_per_second` | `node_wifi_station_receive_bits_per_second` | gauge | node_exporter's name, in bits per second. |
| `wifi_station_transmit_kilobits_per_second` | `node_wifi_station_transmit_bits_per_second` | gauge | node_exporter's name, in bits per second. |
| `wifi_station_receive_bytes_total` | `node_wifi_station_receive_bytes_total` | counter | node_exporter's name. |
| `wifi_station_transmit_bytes_total` | `node_wifi_station_transmit_bytes_total` | counter | node_exporter's name. |
| `wifi_station_signal_dbm` | `node_wifi_station_signal_dbm` | gauge | node_exporter's name. |
| — | `node_wifi_station_transmit_retries_total`, `node_wifi_station_transmit_failed_total`, `node_wifi_station_beacon_loss_total` | counter | New: node_exporter's, where the driver reports them. |
| `wifi_station_transmit_packets_total` | `node_wifi_station_transmitted_packets_total` | counter | node_exporter's name. |
| `wifi_station_receive_packets_total` | `node_wifi_station_received_packets_total` | counter | node_exporter's name. |
| `wifi_station_expected_throughput_kilobits_per_second` | `node_wifi_station_expected_throughput_bits_per_second` | gauge | Base unit, `node_wifi_` namespace. |
| `dawn_ap_stations_total` | `dawn_ap_stations` | gauge | A gauge has no `_total`. |

The hostapd_stations and hostapd_ubus_stations families already followed the conventions and are unchanged.

## Hardware and system collectors

| Before | After | Type | Why |
|---|---|---|---|
| `node_hwmon_*{chip}` | `node_hwmon_*{chip}` | gauge | node_exporter's chip names: each part lowercased with every character but `a-z`, `0-9`, `:` and `_` an underscore (`platform_nct6775.656` is `platform_nct6775_656`), and chips that would share a name told apart by their name file or `hwmonN`. |
| `node_hwmon_chip_names{chip,chip_name}` | unchanged | gauge | `chip_name` cleaned as node_exporter does; written only for chips with a name file. node_exporter's help. |
| `node_hwmon_sensor_label`, `node_hwmon_temp_celsius`, `node_hwmon_pwm` | unchanged | gauge | node_exporter's help texts. |
| `node_thermal_zone_temp{zone,type,policy,mode,passive}` | `node_thermal_zone_temp{zone,type}` | gauge | node_exporter's labels and help; a mode change no longer starts a new series. |
| — (labels of `node_thermal_zone_temp`) | `node_thermal_zone_info{zone,type,policy,mode}` | gauge | The policy and mode, as an info metric. |
| — (label `passive`, in millidegrees) | `node_thermal_zone_passive_celsius{zone,type}` | gauge | The passive trip point as a value, in degrees. |
| `node_os_info` | unchanged | gauge | node_exporter's help text. |
| — | `node_os_version{id,name}` | gauge | New: node_exporter's, the major.minor of the release (none for a snapshot). |
| `dhcp_host_info{name,mac,ip}` | `node_openwrt_dhcp_host_info{name,mac,ip}` | gauge | In OpenWrt's own namespace. |

filesystem and textfile already had node_exporter's names; `node_openwrt_info` is unchanged.

## Service collectors

### dnsmasq

| Before | After | Type | Why |
|---|---|---|---|
| `dnsmasq_<key>_total` of a counter (`dns_*`, `dhcp_*`, `bootp`, `pxe`, `noanswer`, `leases_*`) | unchanged | gauge → counter | They count up from dnsmasq's start. |
| `dnsmasq_dnssec_max_crypto_use_total`, `dnsmasq_dnssec_max_sig_fail_total`, `dnsmasq_dnssec_max_work_total` | `dnsmasq_dnssec_max_crypto_use`, `dnsmasq_dnssec_max_sig_fail`, `dnsmasq_dnssec_max_work` | gauge | High-water marks, not counters: no `_total`. |
| `dnsmasq_tcp_connections_total` | `dnsmasq_tcp_connections` | gauge | The TCP connections open now. |
| `dnsmasq_<key>_total` of a key a later dnsmasq adds | `dnsmasq_<key>` | gauge → untyped | Not known to be a counter. |

### ltq-dsl

| Before | After | Type | Why |
|---|---|---|---|
| `dsl_up{detail}` | `dsl_up` | gauge | A boolean without a label that changes with the state. |
| — (label `detail` of `dsl_up`) | `dsl_state_info{state}` | gauge | The driver's state of the line, as an info metric. |
| `dsl_aggregated_transmit_power_db{direction}` | `dsl_aggregated_transmit_power_dbm{direction}` | gauge | A power, in dBm. |
| `dsl_datarate{direction}` | `dsl_data_rate_bits_per_second{direction}` | gauge | Base unit in the name. |
| `dsl_max_datarate{direction}` | `dsl_max_data_rate_bits_per_second{direction}` | gauge | Base unit in the name. |

The other `dsl_*` families are unchanged.

### wireguard

| Before | After | Type | Why |
|---|---|---|---|
| `wireguard_sent_bytes_total{interface,public_key}` | `wireguard_sent_bytes_total{interface,public_key,allowed_ips,friendly_name}` | counter | prometheus_wireguard_exporter's labels and help. |
| `wireguard_received_bytes_total{interface,public_key}` | `wireguard_received_bytes_total{interface,public_key,allowed_ips,friendly_name}` | counter | prometheus_wireguard_exporter's labels and help. |
| `wireguard_latest_handshake_seconds{interface,public_key}` | `wireguard_latest_handshake_seconds{interface,public_key,allowed_ips,friendly_name}` | gauge | prometheus_wireguard_exporter's labels and help. |
| `wireguard_interface_info{name,public_key,listen_port,fwmark}` | `wireguard_interface_info{interface,public_key,listen_port,fwmark}` | gauge | `interface`, as in the other families; an unset fwmark is left out, not `NaN`. |
| `wireguard_peer_info{interface,public_key,description,endpoint,persistent_keepalive_interval}` | `wireguard_peer_info{interface,public_key,friendly_name,endpoint,persistent_keepalive_interval}` | gauge | `friendly_name`, as in the other families; an unset keepalive is left out, not `NaN`. |

### mwan3

| Before | After | Type | Why |
|---|---|---|---|
| `mwan3_interface_age` | `mwan3_interface_age_seconds` | counter → gauge | Seconds since the last check: goes back to 0. |
| `mwan3_interface_online` | `mwan3_interface_online_seconds` | counter → gauge | Goes back to 0 when the interface goes offline. |
| `mwan3_interface_offline` | `mwan3_interface_offline_seconds` | counter → gauge | Goes back to 0 when the interface comes online. |
| `mwan3_interface_uptime` | `mwan3_interface_uptime_seconds` | counter → gauge | An uptime, with its unit. |
| `mwan3_interface_lost` | unchanged | counter → gauge | Probes lost in the current check. |
| `mwan3_interface_turn` | unchanged | counter → gauge | Rounds in the current check. |

`mwan3_interface_score`, `_status` (one series per state), `_enabled`, `_running` and `_up` are unchanged.

### bmx7

| Before | After | Type | Why |
|---|---|---|---|
| `bmx7_status{id,name,address,revision}` | `bmx7_info{id,name,address,revision}` | gauge | A metric of labels only is `_info`. |
| `bmx7_cpu_usage` (percent) | `bmx7_cpu_usage_ratio` | gauge | A ratio. |
| `bmx7_mem_usage` | `bmx7_memory_usage_bytes` | gauge | Base unit in the name. |
| `bmx7_link_rxRate{source,target,name,dev}` | `bmx7_link_receive_rate_bits_per_second{source,target,name,device}` | gauge | snake_case, base unit, the usual `device` label. |
| `bmx7_link_txRate{source,target,name,dev}` | `bmx7_link_transmit_rate_bits_per_second{source,target,name,device}` | gauge | snake_case, base unit, the usual `device` label. |
| `bmx7_tunIn{name,network}` | `bmx7_tun_in_info{name,network}` | gauge | snake_case, `_info`. |
| `bmx7_plugin{name}` | `bmx7_plugin_info{name}` | gauge | `_info`. |

### modemmanager

| Before | After | Type | Why |
|---|---|---|---|
| `modemmanager_signal_quality` (percent) | `modemmanager_signal_quality_ratio` | gauge | A ratio. |
| `modemmanager_signal_<tech>_<measure>` | `modemmanager_signal_<tech>_<measure>_<unit>`: `_dbm` for rssi, rsrp, rscp and io, `_db` for rsrq, snr, sinr and ecio, `_seconds` for the refresh rate; none for a measure not known | gauge | Unit in the name. |

### ubnt-manager

Every family is a gauge (`ubnt_uptime` and `ubnt_timestamp` were counters) labeled `device`.

| Before | After | Why |
|---|---|---|
| labels `hostname,devmodel,fwversion,essid` of `ubnt_uptime` | `ubnt_info{device,hostname,devmodel,fwversion,essid}` | The radio's names, as an info metric. |
| `ubnt_uptime` | `ubnt_uptime_seconds` | Unit; a gauge. |
| `ubnt_timestamp` | `ubnt_time_seconds` | The radio's clock: a gauge, as `node_time_seconds`. |
| `ubnt_totalram`, `ubnt_freeram` | `ubnt_memory_total_bytes`, `ubnt_memory_free_bytes` | Bytes (airOS 6 reports kB, airOS 8 bytes). |
| `ubnt_cpuload` (percent) | `ubnt_cpu_load_ratio` | A ratio. |
| `ubnt_cpubusy`, `ubnt_cputotal` | `ubnt_cpu_busy`, `ubnt_cpu_all` | No `_total` on a gauge. |
| `ubnt_temperature` | `ubnt_temperature_celsius` | Unit. |
| `ubnt_frequency`, `ubnt_center1_freq`, `ubnt_chanbw` (MHz) | `ubnt_frequency_hertz`, `ubnt_center1_frequency_hertz`, `ubnt_channel_width_hertz` | Base unit. |
| `ubnt_signal`, `ubnt_noisef`, `ubnt_txpower` | `ubnt_signal_dbm`, `ubnt_noise_floor_dbm`, `ubnt_transmit_power_dbm` | Unit. |
| `ubnt_distance` | `ubnt_distance_meters` | Unit. |
| `ubnt_txrate`, `ubnt_rxrate` (Mbit/s) | `ubnt_transmit_rate_bits_per_second`, `ubnt_receive_rate_bits_per_second` | Base unit. |
| `ubnt_throughput_tx`, `ubnt_throughput_rx` (kbit/s) | `ubnt_transmit_throughput_bits_per_second`, `ubnt_receive_throughput_bits_per_second` | Base unit. |
| `ubnt_polling_cb_capacity`, `_dl_capacity`, `_ul_capacity` (kbit/s) | `ubnt_airmax_combined_capacity_bits_per_second`, `ubnt_airmax_downlink_capacity_bits_per_second`, `ubnt_airmax_uplink_capacity_bits_per_second` | Base unit. |
| `ubnt_use`, `ubnt_tx_use`, `ubnt_rx_use` | `ubnt_airtime_use`, `ubnt_transmit_airtime_use`, `ubnt_receive_airtime_use` | Named for what they are; left as airOS reports them, their scale unknown. |
| `ubnt_count` | `ubnt_stations` | Named for what it counts. |
| `ubnt_aprepeater`, `ubnt_rstatus` | `ubnt_ap_repeater`, `ubnt_radio_status` | snake_case. |

`ubnt_loadavg`, `ubnt_channel`, `ubnt_band`, `ubnt_dfs`, `ubnt_rssi`, `ubnt_rx_chainmask`, `ubnt_tx_chainmask`, `ubnt_cac_state`, `ubnt_cac_timeout`, `ubnt_rx_idx`, `ubnt_rx_nss`, `ubnt_tx_idx`, `ubnt_tx_nss` and `ubnt_atpc_status` keep their names.

### unbound

The counters of each thread (`threadN.*` in unbound's statistics), labeled `thread`, where the Lua exporter had the `total.*` ones without labels, as letsencrypt/unbound_exporter has them; `sum without (thread)` gives the totals.

| Before | After | Type | Why |
|---|---|---|---|
| `unbound_num_queries_total` | `unbound_queries_total{thread}` | counter | unbound_exporter's name. |
| `unbound_num_queries_ip_ratelimited_total` | `unbound_queries_ip_ratelimited_total{thread}` | counter | As unbound_exporter's other query counters. |
| `unbound_num_queries_cookie_valid_total`, `_cookie_client_total`, `_cookie_invalid_total` | `unbound_queries_cookie_valid_total{thread}`, `unbound_queries_cookie_client_total{thread}`, `unbound_queries_cookie_invalid_total{thread}` | counter | unbound_exporter's names. |
| `unbound_num_queries_discard_timeout_total`, `_wait_limit_total` | `unbound_queries_discard_timeout_total{thread}`, `unbound_queries_wait_limit_total{thread}` | counter | unbound_exporter's names, with the `_total` they lack there. |
| — | `unbound_queries_replyaddr_limit_total{thread}` | counter | New: unbound_exporter's, with `_total`. |
| `unbound_cachehits_total` | `unbound_cache_hits_total{thread}` | counter | unbound_exporter's name. |
| `unbound_cachemiss_total` | `unbound_cache_misses_total{thread}` | counter | unbound_exporter's name. |
| `unbound_prefetch_total` | `unbound_prefetches_total{thread}` | counter | unbound_exporter's name. |
| `unbound_num_queries_timed_out_total` | `unbound_queries_timed_out_total{thread}` | counter | As unbound_exporter's other query counters. |
| `unbound_query_queue_time_us_max` (µs) | `unbound_query_queue_time_seconds_max{thread}` | gauge | Base unit. |
| `unbound_num_expired_total` | `unbound_expired_total{thread}` | counter | unbound_exporter's name. |
| `unbound_num_recursivereplies_total` | `unbound_recursive_replies_total{thread}` | counter | unbound_exporter's name. |
| `unbound_num_dns_error_reports_total` | `unbound_dns_error_reports_total{thread}` | counter | unbound_exporter's name, with the `_total` it lacks there. |
| `unbound_requestlist_avg`, `unbound_requestlist_max` | `unbound_request_list_avg{thread}`, `unbound_request_list_max{thread}` | gauge | As unbound_exporter's other request list families. |
| `unbound_requestlist_overwritten_total`, `_exceeded_total` | `unbound_request_list_overwritten_total{thread}`, `unbound_request_list_exceeded_total{thread}` | counter | unbound_exporter's names. |
| `unbound_requestlist_current_all`, `_current_user` | `unbound_request_list_current_all{thread}`, `unbound_request_list_current_user{thread}` | gauge | unbound_exporter's names. |
| — | `unbound_request_list_current_replies{thread}` | gauge | New: unbound_exporter's. |
| `unbound_recursion_time_avg`, `unbound_recursion_time_median` | `unbound_recursion_time_seconds_avg`, `unbound_recursion_time_seconds_median` | gauge | unbound_exporter's names, from `total.*`. |

## New metrics

Neither upstream exporter had these. Where node_exporter has the metric, the name, type, labels and help are its own.

| Collector | Families | Type | Source |
|---|---|---|---|
| — (the exporter's own) | `ucode_prometheus_exporter_build_info{version}` | gauge | 1, labeled with the package's version (`2026.09.30-r1`, `dev` from a source tree), in every scrape whatever `collect[]` selects; as node_exporter's `node_exporter_build_info`. |
| — (the exporter's own) | `node_scrape_collector_observing{collector}` | gauge | Beside node_exporter's `node_scrape_collector_success`: 0 for a collector with nothing to observe (its hardware, kernel feature or service is not there; it succeeds without samples), 1 for every other; see the README's "Nothing to observe". |
| conntrack (base) | `node_nf_conntrack_stat_{found,invalid,ignore,insert,insert_failed,drop,early_drop,search_restart}` | gauge | node_exporter's, from `/proc/net/stat/nf_conntrack` summed over the CPUs. |
| softnet (base) | `node_softnet_{processed,dropped,times_squeezed,cpu_collision,received_rps,flow_limit_count}_total{cpu}` | counter | node_exporter's, from `/proc/net/softnet_stat`. |
| softnet (base) | `node_softnet_backlog_len{cpu}` | gauge | node_exporter's. |
| vmstat (base) | `node_vmstat_<field>` (default fields: `oom_kill`, `pgpg*`, `pswp*`, `pg*fault*`; option `fields`) | untyped | node_exporter's, from `/proc/vmstat`. |
| openwrt_interfaces (base) | `node_openwrt_interface_{up,pending,available,autostart}{interface}` | gauge | netifd's `network.interface dump`, 0 or 1. |
| openwrt_interfaces (base) | `node_openwrt_interface_uptime_seconds{interface}` | gauge | netifd's uptime, while the interface is up. |
| openwrt_interfaces (base) | `node_openwrt_interface_info{interface,proto,device,l3_device}` | gauge | 1; a label netifd does not report is left out. |
| openwrt_interfaces (base) | `node_openwrt_interface_addresses{interface,family}`, `node_openwrt_interface_routes{interface,family}` | gauge | Counts: an address as a label would change with every WAN lease. |
| openwrt_interfaces (base) | `node_openwrt_interface_ipv6_prefixes{interface}`, `node_openwrt_interface_errors{interface}` | gauge | Delegated prefixes; the errors netifd holds for the interface. |
| dhcp_leases | `node_openwrt_dhcp_leases{server,interface,family}` | gauge | Active leases of dnsmasq (its lease file) and odhcpd (`ubus call dhcp ipv4leases`/`ipv6leases`). |
| dhcp_leases (option `leases`) | `node_openwrt_dhcp_lease_info{server,interface,family,address,mac,duid,iaid,hostname}`, `node_openwrt_dhcp_lease_expiry_timestamp_seconds{server,interface,family,address}` | gauge | A series per lease; off by default, for churn and privacy. |
| timesync (base) | `node_timesync_synchronized{daemon}` | gauge | 1 or 0, for each NTP daemon procd runs: `ntpd` (busybox, from its last event, kept by the base package's hotplug script: synchronized below stratum 16) and `chronyd` (`chronyc -c tracking`: synchronized unless its leap status is `Not synchronised`). node_exporter's `node_timex_sync_status` is the kernel's adjtimex(2) state, which ucode cannot read: not the same, so not its name. |
| timesync (base) | `node_timesync_stratum{daemon}`, `node_timesync_offset_seconds{daemon}`, `node_timesync_last_update_timestamp_seconds{daemon}` | gauge | While synchronized: the stratum, the offset at the last update (chronyd's last offset, ntpd's event's), and when that was (chronyd's reference time, ntpd's event) as a timestamp, as the conventions want a time since something. Not node_exporter's `node_timex_offset_seconds`, the offset the kernel still has to slew. |
| qdisc | `node_qdisc_{bytes,packets,drops,requeues,overlimits}_total{device,kind}` | counter | node_exporter's (collector/qdisc_linux.go), from `tc -s -j qdisc show`: the root qdisc of each device, as node_exporter reports them; noqueue is left out. |
| qdisc | `node_qdisc_current_queue_length{device,kind}`, `node_qdisc_backlog{device,kind}` | gauge | node_exporter's: packets and bytes queued. |
| qdisc | `node_qdisc_cake_capacity_estimate_bytes_per_second{device}`, `node_qdisc_cake_memory_used_bytes{device}`, `node_qdisc_cake_memory_limit_bytes{device}` | gauge | A root CAKE qdisc's shaper rate and memory. No CAKE exporter is widely used: tc's JSON keys (tc/q_cake.c), in base units. |
| qdisc | `node_qdisc_cake_tin_{bytes,packets,drops,ecn_marks,ack_drops}_total{device,tin}` | counter | Per tin, `tin` its index as tc numbers them (0 for besteffort; 0 to 3, Bulk to Voice, for diffserv4). |
| qdisc | `node_qdisc_cake_tin_{threshold_rate_bytes_per_second,backlog_bytes,peak_delay_seconds,average_delay_seconds,base_delay_seconds,sparse_flows,bulk_flows,unresponsive_flows}{device,tin}` | gauge | Per tin; tc's delays in µs, here in seconds (`base` is tc's `sp_delay`, the sparse flows' delay). |

## Unchanged collectors

conntrack (beyond the statistics above), entropy, filefd, filesystem, hostapd_stations, hostapd_ubus_stations, loadavg, realtek-poe, textfile, time and uname write the families they wrote before.

## Standalone exporters

| Service | Exporter | Followed? |
|---|---|---|
| unbound | [letsencrypt/unbound_exporter](https://github.com/letsencrypt/unbound_exporter) | Yes: its names, help texts and per-thread `thread` label, with `_total` added to the counters it names without (`queries_discard_timeout`, `queries_wait_limit`, `queries_replyaddr_limit`, `dns_error_reports`). |
| WireGuard | [prometheus_wireguard_exporter](https://github.com/MindFlavor/prometheus_wireguard_exporter) | Yes: `wireguard_sent_bytes_total`, `wireguard_received_bytes_total` and `wireguard_latest_handshake_seconds`, its help texts and labels (`interface`, `public_key`, `allowed_ips`, `friendly_name`). |
| dnsmasq | [google/dnsmasq_exporter](https://github.com/google/dnsmasq_exporter) | No: its counters (`dnsmasq_hits`, `dnsmasq_misses`, ...) have no `_total` and are typed as gauges, and they are the cache figures of dnsmasq's CHAOS TXT records, not the `ubus call dnsmasq metrics` this collector reads. |
