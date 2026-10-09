'use strict';

// What the migration page (docs/reference/migration.md) says that the sources
// do not: devenv/scripts/docs_gen/migration.uc reads it with
// docs/gen/feed-exporters.json, what the feed's exporters write (make
// feed-inventory), and with what this exporter's collectors write (as
// metrics.md has it), and refuses, writing nothing, an entry either
// contradicts: a family of the feed's that has no entry here, an entry for a
// family neither writes, a label the collector's source has no key for, a
// family of this exporter's that none of its collectors writes.

// What a name the sources compute stands for, as the page shows it.
export const computed = {
	'node_memory_<>_bytes': 'node_memory_<Field>_bytes',
	'node_network_<>': 'node_network_{receive,transmit}_<field>_total',
	'node_netstat_<>_<>': 'node_netstat_<Section>_<Field>',
	'snmp6_<>': 'snmp6_<Field>',
	'<>': 'node_ethtool_<statistic>',
	'modemmanager_signal_<>_<>': 'modemmanager_signal_<technology>_<measure>',
	'dnsmasq_<>_total': 'dnsmasq_<key>_total',
};

// This exporter's collector of each of the feed's whose name is not one of
// its own: null for the scrape's own families.
export const collectors = {
	'nft_counters': 'nft-counters',
	'wifi_stations': 'wifi',
	'(scrape)': null,
};

// The packages of the feed's that have no package of this exporter's of the
// same name, and what does their job.
export const packages = {
	'prometheus-node-exporter-lua-wifi_stations': 'No package: wifi writes the stations, with its option `stations`, on by default. `ucode-prometheus-exporter-wifi`.',
};

// Each family of the feed's exporters, by its name (a computed one as
// `computed` shows it): `labels`, those it has, or { lua, ucode } where the
// two differ; `to`, what this exporter writes for it, a family or a list,
// null where nothing does; `change` 'relabeled' where the label names are the
// same and their values are not; `alias` where the value is the same, so that
// a Prometheus rule renaming the old family to the new one is sound; `note`.
// A family missing says why and what to use.
export const families = {
	// ---- the scrape's own ----
	'node_scrape_collector_duration_seconds': { labels: [ 'collector' ], to: 'node_scrape_collector_duration_seconds' },
	'node_scrape_collector_success': { labels: [ 'collector' ], to: 'node_scrape_collector_success', note: 'Also 0 for a collector the deadline left out or a circuit breaker quarantined; `node_scrape_collector_observing` says which have nothing to observe.' },

	// ---- base ----
	'node_boot_time_seconds': { labels: [], to: 'node_boot_time_seconds' },
	'node_context_switches_total': { labels: [], to: 'node_context_switches_total' },
	'node_cpu_seconds_total': { labels: [ 'cpu', 'mode' ], to: [ 'node_cpu_seconds_total', 'node_cpu_guest_seconds_total' ], change: 'relabeled', note: '`cpu` is the CPU\'s number, `0` where it was `cpu0`; the modes `guest` and `guest_nice` are `node_cpu_guest_seconds_total{mode="user"|"nice"}`, as node_exporter has them.' },
	'node_forks_total': { labels: [], to: 'node_forks_total' },
	'node_intr_total': { labels: [], to: 'node_intr_total' },
	'node_procs_blocked_total': { labels: [], to: 'node_procs_blocked', alias: true, note: 'A gauge has no `_total`.' },
	'node_procs_running_total': { labels: [], to: 'node_procs_running', alias: true, note: 'A gauge has no `_total`.' },
	'node_nf_conntrack_entries': { labels: [], to: 'node_nf_conntrack_entries' },
	'node_nf_conntrack_entries_limit': { labels: [], to: 'node_nf_conntrack_entries_limit' },
	'node_entropy_available_bits': { labels: [], to: 'node_entropy_available_bits' },
	'node_entropy_pool_size_bits': { labels: [], to: 'node_entropy_pool_size_bits' },
	'node_filefd_allocated': { labels: [], to: 'node_filefd_allocated' },
	'node_filefd_maximum': { labels: [], to: 'node_filefd_maximum' },
	'node_load1': { labels: [], to: 'node_load1' },
	'node_load5': { labels: [], to: 'node_load5' },
	'node_load15': { labels: [], to: 'node_load15' },
	'node_memory_<Field>_bytes': { labels: [], to: [ 'node_memory_<Field>_bytes', 'node_memory_<Field>' ], note: 'The page counts, `HugePages_Total`, `_Free`, `_Rsvd` and `_Surp`, have no `_bytes`, as node_exporter names them.' },
	'node_network_{receive,transmit}_<field>_total': { labels: [ 'device' ], to: 'node_network_<receive|transmit>_<field>_total', note: 'The same 16 families of `/proc/net/dev`, and `node_network_receive_nohandler_total` besides.' },
	'node_network_receive_bytes_total': { labels: [ 'device' ], to: 'node_network_receive_bytes_total' },
	'node_network_receive_packets_total': { labels: [ 'device' ], to: 'node_network_receive_packets_total' },
	'node_network_receive_errs_total': { labels: [ 'device' ], to: 'node_network_receive_errs_total' },
	'node_network_receive_drop_total': { labels: [ 'device' ], to: 'node_network_receive_drop_total' },
	'node_network_receive_fifo_total': { labels: [ 'device' ], to: 'node_network_receive_fifo_total' },
	'node_network_receive_frame_total': { labels: [ 'device' ], to: 'node_network_receive_frame_total' },
	'node_network_receive_compressed_total': { labels: [ 'device' ], to: 'node_network_receive_compressed_total' },
	'node_network_receive_multicast_total': { labels: [ 'device' ], to: 'node_network_receive_multicast_total' },
	'node_network_transmit_bytes_total': { labels: [ 'device' ], to: 'node_network_transmit_bytes_total' },
	'node_network_transmit_packets_total': { labels: [ 'device' ], to: 'node_network_transmit_packets_total' },
	'node_network_transmit_errs_total': { labels: [ 'device' ], to: 'node_network_transmit_errs_total' },
	'node_network_transmit_drop_total': { labels: [ 'device' ], to: 'node_network_transmit_drop_total' },
	'node_network_transmit_fifo_total': { labels: [ 'device' ], to: 'node_network_transmit_fifo_total' },
	'node_network_transmit_colls_total': { labels: [ 'device' ], to: 'node_network_transmit_colls_total' },
	'node_network_transmit_carrier_total': { labels: [ 'device' ], to: 'node_network_transmit_carrier_total' },
	'node_network_transmit_compressed_total': { labels: [ 'device' ], to: 'node_network_transmit_compressed_total' },
	'node_selinux_current_mode': { labels: [], to: 'node_selinux_current_mode' },
	'node_selinux_enabled': { labels: [], to: 'node_selinux_enabled' },
	'node_time_seconds': { labels: [], to: 'node_time_seconds' },
	'node_uname_info': { labels: [ 'domainname', 'machine', 'nodename', 'release', 'sysname', 'version' ], to: 'node_uname_info' },
	'node_network_info': { labels: [ 'device', 'address', 'broadcast', 'duplex', 'operstate', 'ifalias' ], to: 'node_network_info', note: '`adminstate` added, as node_exporter has it.' },
	'node_network_speed_bytes': { labels: [ 'device' ], to: 'node_network_speed_bytes', note: 'A link of 0 Mb/s is 0, where it was left out.' },
	'node_network_address_assign_type': { labels: [ 'device' ], to: 'node_network_address_assign_type' },
	'node_network_carrier': { labels: [ 'device' ], to: 'node_network_carrier' },
	'node_network_carrier_changes_total': { labels: [ 'device' ], to: 'node_network_carrier_changes_total' },
	'node_network_carrier_down_changes_total': { labels: [ 'device' ], to: 'node_network_carrier_down_changes_total' },
	'node_network_carrier_up_changes_total': { labels: [ 'device' ], to: 'node_network_carrier_up_changes_total' },
	'node_network_device_id': { labels: [ 'device' ], to: 'node_network_device_id' },
	'node_network_dormant': { labels: [ 'device' ], to: 'node_network_dormant' },
	'node_network_flags': { labels: [ 'device' ], to: 'node_network_flags' },
	'node_network_iface_id': { labels: [ 'device' ], to: 'node_network_iface_id' },
	'node_network_iface_link': { labels: [ 'device' ], to: 'node_network_iface_link' },
	'node_network_iface_link_mode': { labels: [ 'device' ], to: 'node_network_iface_link_mode' },
	'node_network_mtu_bytes': { labels: [ 'device' ], to: 'node_network_mtu_bytes' },
	'node_network_name_assign_type': { labels: [ 'device' ], to: 'node_network_name_assign_type' },
	'node_network_net_dev_group': { labels: [ 'device' ], to: 'node_network_net_dev_group' },
	'node_network_protocol_type': { labels: [ 'device' ], to: 'node_network_protocol_type' },
	'node_network_transmit_queue_length': { labels: [ 'device' ], to: 'node_network_transmit_queue_length' },

	// ---- bmx7 ----
	'bmx7_status': { labels: [ 'id', 'name', 'address', 'revision' ], to: 'bmx7_info', alias: true, note: 'A metric of labels only is `_info`.' },
	'bmx7_cpu_usage': { labels: [], to: 'bmx7_cpu_usage_ratio', note: 'A ratio of 0 to 1, where it was a percentage: divide by 100.' },
	'bmx7_mem_usage': { labels: [], to: 'bmx7_memory_usage_bytes', alias: true },
	'bmx7_link_rxRate': { labels: [ 'source', 'target', 'name', 'dev' ], to: 'bmx7_link_receive_rate_bits_per_second', note: '`dev` is `device`.' },
	'bmx7_link_txRate': { labels: [ 'source', 'target', 'name', 'dev' ], to: 'bmx7_link_transmit_rate_bits_per_second', note: '`dev` is `device`.' },
	'bmx7_tunIn': { labels: [ 'name', 'network' ], to: 'bmx7_tun_in_info', alias: true },
	'bmx7_plugin': { labels: [ 'name' ], to: 'bmx7_plugin_info', alias: true },

	// ---- dawn ----
	'dawn_ap_channel_utilization_ratio': { labels: [ 'ssid', 'bssid', 'freq', 'hostname', 'ht_support', 'vht_support', 'neighbor_report' ], to: 'dawn_ap_channel_utilization_ratio' },
	'dawn_ap_stations_total': { labels: [ 'ssid', 'bssid', 'freq', 'hostname', 'ht_support', 'vht_support', 'neighbor_report' ], to: 'dawn_ap_stations', alias: true, note: 'A gauge has no `_total`.' },
	'dawn_station_signal_dbm': { labels: [ 'ssid', 'bssid', 'mac', 'ht_support', 'vht_support' ], to: 'dawn_station_signal_dbm' },

	// ---- dnsmasq ----
	'dnsmasq_<key>_total': { labels: [], to: [ 'dnsmasq_<key>_total', 'dnsmasq_<key>' ], note: 'Counters keep their name, typed counter; the high-water marks (`dnssec_max_crypto_use`, `dnssec_max_sig_fail`, `dnssec_max_work`) and `tcp_connections`, gauges, lose `_total`.' },

	// ---- ethtool ----
	'node_ethtool_<statistic>': { labels: [ 'device' ], to: [ 'node_ethtool_<statistic>', 'node_network_supported_speed_bytes', 'node_network_supported_port_info' ], change: 'relabeled', note: 'Each statistic named as node_exporter names it (`rx` and `tx` spelled out only between underscores); only the links a device backs. The link\'s modes, ports, pause and autonegotiation, which the Lua exporter wrote as untyped families labeled `device` alone, are node_exporter\'s, a series per mode or port (`node_network_supported_speed_bytes{device,duplex,mode}`, ...).' },

	// ---- filesystem ----
	'node_filesystem_avail_bytes': { labels: [ 'device', 'fstype', 'mountpoint' ], to: 'node_filesystem_avail_bytes' },
	'node_filesystem_free_bytes': { labels: [ 'device', 'fstype', 'mountpoint' ], to: 'node_filesystem_free_bytes' },
	'node_filesystem_size_bytes': { labels: [ 'device', 'fstype', 'mountpoint' ], to: 'node_filesystem_size_bytes' },
	'node_filesystem_readonly': { labels: [ 'device', 'fstype', 'mountpoint' ], to: 'node_filesystem_readonly' },
	'node_filesystem_files': { labels: [ 'device', 'fstype', 'mountpoint' ], to: 'node_filesystem_files', note: 'Where rpcd has loaded the package\'s plugin, `prometheus-exporter.filesystem`.' },
	'node_filesystem_files_free': { labels: [ 'device', 'fstype', 'mountpoint' ], to: 'node_filesystem_files_free', note: 'As `node_filesystem_files`.' },

	// ---- hostapd_stations ----
	'hostapd_station_receive_packets_total': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: [ 'hostapd_station_receive_packets_total', 'hostapd_station_info' ], note: 'The network\'s labels are on `hostapd_station_info{vif,station,ssid,bssid,encryption,frequency,channel}`, one per station (since 0.2.1): a channel change starts no new series.' },
	'hostapd_station_receive_bytes_total': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_receive_bytes_total', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_transmit_packets_total': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_transmit_packets_total', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_transmit_bytes_total': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_transmit_bytes_total', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_signal_dbm': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_signal_dbm', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_flag_auth': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_flag_auth', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_flag_assoc': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_flag_assoc', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_flag_ht': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_flag_ht', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_flag_vht': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_flag_vht', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_flag_he': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_flag_he', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_flag_mfp': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_flag_mfp', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_flag_wmm': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_flag_wmm', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_vht_capb_su_beamformee': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_vht_capb_su_beamformee', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_vht_capb_mu_beamformee': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: 'hostapd_station_vht_capb_mu_beamformee', note: 'As `hostapd_station_receive_packets_total`.' },
	'hostapd_station_connected_seconds_total': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: null, note: 'Read from hostapd\'s ubus `get_clients`, where the Lua exporter ran `hostapd_cli all_sta`: it has no connected time. Use wifi\'s `node_wifi_station_connected_seconds_total{radio,device,mac_address}`, from nl80211.' },
	'hostapd_station_inactive_seconds': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: null, note: '`get_clients` has no inactive time. Use wifi\'s `node_wifi_station_inactive_seconds`.' },
	'hostapd_station_flag_short_preamble': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: null, note: '`get_clients` has no short preamble flag, and nl80211 has it for a 2.4 GHz legacy station only; nothing writes it.' },
	'hostapd_station_sae_group': { labels: [ 'vif', 'ssid', 'bssid', 'encryption', 'frequency', 'channel', 'station' ], to: null, note: '`get_clients` has no SAE group; nothing writes it. `hostapd_cli -i <vif> sta <mac>` says it, in a textfile script.' },

	// ---- hostapd_ubus_stations ----
	'hostapd_ubus_station_rrm_caps_link_measurement': { labels: [ 'ifname', 'freq', 'station' ], to: 'hostapd_ubus_station_rrm_caps_link_measurement' },
	'hostapd_ubus_station_rrm_caps_neighbor_report': { labels: [ 'ifname', 'freq', 'station' ], to: 'hostapd_ubus_station_rrm_caps_neighbor_report' },
	'hostapd_ubus_station_rrm_caps_beacon_report_passive': { labels: [ 'ifname', 'freq', 'station' ], to: 'hostapd_ubus_station_rrm_caps_beacon_report_passive' },
	'hostapd_ubus_station_rrm_caps_beacon_report_active': { labels: [ 'ifname', 'freq', 'station' ], to: 'hostapd_ubus_station_rrm_caps_beacon_report_active' },
	'hostapd_ubus_station_rrm_caps_beacon_report_table': { labels: [ 'ifname', 'freq', 'station' ], to: 'hostapd_ubus_station_rrm_caps_beacon_report_table' },
	'hostapd_ubus_station_rrm_caps_lci_measurement': { labels: [ 'ifname', 'freq', 'station' ], to: 'hostapd_ubus_station_rrm_caps_lci_measurement' },
	'hostapd_ubus_station_rrm_caps_ftm_range_report': { labels: [ 'ifname', 'freq', 'station' ], to: 'hostapd_ubus_station_rrm_caps_ftm_range_report' },

	// ---- hwmon ----
	'node_hwmon_chip_names': { labels: [ 'chip', 'chip_name' ], to: 'node_hwmon_chip_names', change: 'relabeled', note: '`chip` and `chip_name` as node_exporter cleans them (`platform_nct6775.656` is `platform_nct6775_656`); written for chips with a name file only.' },
	'node_hwmon_sensor_label': { labels: [ 'chip', 'sensor', 'label' ], to: 'node_hwmon_sensor_label', change: 'relabeled', note: '`chip` as node_exporter names it.' },
	'node_hwmon_temp_celsius': { labels: [ 'chip', 'sensor' ], to: 'node_hwmon_temp_celsius', change: 'relabeled', note: '`chip` as node_exporter names it.' },
	'node_hwmon_pwm': { labels: [ 'chip', 'sensor' ], to: 'node_hwmon_pwm', change: 'relabeled', note: '`chip` as node_exporter names it.' },

	// ---- ltq-dsl ----
	'dsl_info': { labels: [ 'atuc_vendor', 'atuc_system_vendor', 'chipset', 'firmware_version', 'api_version', 'driver_version' ], to: 'dsl_info' },
	'dsl_line_info': { labels: [ 'annex', 'standard', 'mode', 'profile' ], to: 'dsl_line_info' },
	'dsl_up': { labels: [ 'detail' ], to: [ 'dsl_up', 'dsl_state_info' ], note: 'The line\'s state, `detail`, is `dsl_state_info{state}`: a state change starts no new series of `dsl_up`.' },
	'dsl_uptime_seconds': { labels: [], to: 'dsl_uptime_seconds' },
	'dsl_line_attenuation_db': { labels: [ 'direction' ], to: 'dsl_line_attenuation_db' },
	'dsl_signal_attenuation_db': { labels: [ 'direction' ], to: 'dsl_signal_attenuation_db' },
	'dsl_signal_to_noise_margin_db': { labels: [ 'direction' ], to: 'dsl_signal_to_noise_margin_db' },
	'dsl_aggregated_transmit_power_db': { labels: [ 'direction' ], to: 'dsl_aggregated_transmit_power_dbm', alias: true, note: 'A power, in dBm.' },
	'dsl_latency_seconds': { labels: [ 'direction' ], to: 'dsl_latency_seconds' },
	'dsl_datarate': { labels: [ 'direction' ], to: 'dsl_data_rate_bits_per_second', alias: true },
	'dsl_max_datarate': { labels: [ 'direction' ], to: 'dsl_max_data_rate_bits_per_second', alias: true },
	'dsl_error_seconds_total': { labels: [ 'err', 'loc' ], to: 'dsl_error_seconds_total' },
	'dsl_errors_total': { labels: [ 'err', 'loc' ], to: 'dsl_errors_total' },
	'dsl_erb_total': { labels: [ 'counter' ], to: 'dsl_erb_total' },

	// ---- modemmanager ----
	'modemmanager_signal_quality': { labels: [ 'modem' ], to: 'modemmanager_signal_quality_ratio', note: 'A ratio of 0 to 1, where it was a percentage: divide by 100.' },
	'modemmanager_signal_<technology>_<measure>': { labels: [ 'modem' ], to: 'modemmanager_signal_<technology>_<measure>[_<unit>]', note: 'The unit in the name: `_dbm` for rssi, rsrp, rscp and io, `_db` for rsrq, snr, sinr and ecio, `_seconds` for the refresh rate.' },

	// ---- mwan3 ----
	'mwan3_interface_age': { labels: [ 'interface' ], to: 'mwan3_interface_age_seconds', alias: true, note: 'A gauge: seconds since the last check.' },
	'mwan3_interface_online': { labels: [ 'interface' ], to: 'mwan3_interface_online_seconds', alias: true, note: 'A gauge: back to 0 when the interface goes offline.' },
	'mwan3_interface_offline': { labels: [ 'interface' ], to: 'mwan3_interface_offline_seconds', alias: true, note: 'A gauge: back to 0 when the interface comes online.' },
	'mwan3_interface_uptime': { labels: [ 'interface' ], to: 'mwan3_interface_uptime_seconds', alias: true, note: 'A gauge.' },
	'mwan3_interface_score': { labels: [ 'interface' ], to: 'mwan3_interface_score' },
	'mwan3_interface_lost': { labels: [ 'interface' ], to: 'mwan3_interface_lost', note: 'The probes lost in the current check.' },
	'mwan3_interface_turn': { labels: [ 'interface' ], to: 'mwan3_interface_turn', note: 'The rounds of the current check.' },
	'mwan3_interface_status': { labels: [ 'interface', 'status' ], to: 'mwan3_interface_status' },
	'mwan3_interface_enabled': { labels: [ 'interface' ], to: 'mwan3_interface_enabled' },
	'mwan3_interface_running': { labels: [ 'interface' ], to: 'mwan3_interface_running' },
	'mwan3_interface_up': { labels: [ 'interface' ], to: 'mwan3_interface_up' },

	// ---- nat_traffic ----
	'node_nat_traffic': { labels: [ 'src', 'dest' ], to: 'node_nat_traffic_bytes', note: 'A series per host on this side of the router (the source of a connection, or the LAN host a port forward reaches), `host`, where it was one per pair of addresses: `sum by (src)` is `node_nat_traffic_bytes{host}`. The pairs come back with the option `peers`, `{host,peer}` (since 0.3.0).' },

	// ---- netstat ----
	'node_netstat_<Section>_<Field>': { labels: [], to: 'node_netstat_<Protocol>_<Field>', note: 'Untyped, as node_exporter has them; by default only node_exporter\'s fields, some 40 of about 400: the option `fields` takes others (`.*` for every one).' },

	// ---- nft-counters ----
	'nft_counter_packets': { labels: [ 'family', 'table', 'name', 'comment' ], to: 'nft_counter_packets_total', alias: true, note: 'A counter ends in `_total`.' },
	'nft_counter_bytes': { labels: [ 'family', 'table', 'name', 'comment' ], to: 'nft_counter_bytes_total', alias: true, note: 'A counter ends in `_total`.' },

	// ---- openwrt ----
	'node_openwrt_info': { labels: [ 'board_name', 'id', 'model', 'release', 'revision', 'system', 'target' ], to: 'node_openwrt_info' },
	'node_os_info': { labels: [ 'build_id', 'id', 'name', 'pretty_name', 'version', 'version_id' ], to: 'node_os_info' },

	// ---- realtek-poe ----
	'realtek_poe_switch_info': { labels: [ 'mcu', 'firmware' ], to: 'realtek_poe_switch_info' },
	'realtek_poe_switch_budget_watts': { labels: [], to: 'realtek_poe_switch_budget_watts' },
	'realtek_poe_switch_consumption_watts': { labels: [], to: 'realtek_poe_switch_consumption_watts' },
	'realtek_poe_port_priority': { labels: [ 'device' ], to: 'realtek_poe_port_priority' },
	'realtek_poe_port_consumption_watts': { labels: [ 'device' ], to: 'realtek_poe_port_consumption_watts' },
	'realtek_poe_port_state': { labels: [ 'device', 'state' ], to: 'realtek_poe_port_state' },
	'realtek_poe_port_mode': { labels: [ 'device', 'mode' ], to: 'realtek_poe_port_mode' },

	// ---- snmp6 ----
	'snmp6_<Field>': { labels: [ 'device' ], to: [ 'node_snmp6_<Protocol>_<Field>_total', 'node_netstat_<Protocol>_<Field>' ], note: 'A device\'s, `/proc/net/dev_snmp6/<device>`, are `node_snmp6_<Protocol>_<Field>_total{device}` (`snmp6_Ip6InOctets` is `node_snmp6_Ip6_InOctets_total`), 13 by default since 0.3.0: the option `fields` takes others. The whole system\'s, `device="all"`, are netstat\'s `node_netstat_Ip6_*`, `_Icmp6_*`, `_Udp6_*`, without the label. `snmp6_ifIndex` is `node_snmp6_ifindex`, a gauge, not by default: netclass\'s `node_network_iface_id` is the same.' },

	// ---- textfile ----
	'node_textfile_mtime_seconds': { labels: [ 'file' ], to: 'node_textfile_mtime_seconds', note: 'The files are read from the option `directory`, `/var/prometheus` by default as before; one that is not valid exposition text is left out, and `node_textfile_scrape_error` is 1.' },

	// ---- thermal ----
	'node_thermal_zone_temp': { labels: [ 'zone', 'type', 'policy', 'mode', 'passive' ], to: [ 'node_thermal_zone_temp', 'node_thermal_zone_info', 'node_thermal_zone_passive_celsius' ], note: '`policy` and `mode` are on `node_thermal_zone_info`, and the passive trip point is `node_thermal_zone_passive_celsius`, in degrees where `passive` was millidegrees: a mode change starts no new series.' },

	// ---- ubnt-manager ----
	'ubnt_uptime': { labels: [ 'device', 'hostname', 'devmodel', 'fwversion', 'essid' ], to: [ 'ubnt_uptime_seconds', 'ubnt_info' ], note: 'A gauge labeled `device`; the radio\'s names are on `ubnt_info{device,hostname,devmodel,fwversion,essid}`.' },
	'ubnt_timestamp': { labels: [ 'device' ], to: 'ubnt_time_seconds', alias: true, note: 'The radio\'s clock, a gauge.' },
	'ubnt_totalram': { labels: [ 'device' ], to: 'ubnt_memory_total_bytes', note: 'In bytes; airOS 6 reports kB.' },
	'ubnt_freeram': { labels: [ 'device' ], to: 'ubnt_memory_free_bytes', note: 'In bytes; airOS 6 reports kB.' },
	'ubnt_cpuload': { labels: [ 'device' ], to: 'ubnt_cpu_load_ratio', note: 'A ratio of 0 to 1, where it was a percentage.' },
	'ubnt_cpubusy': { labels: [ 'device' ], to: 'ubnt_cpu_busy', alias: true },
	'ubnt_cputotal': { labels: [ 'device' ], to: 'ubnt_cpu_all', alias: true },
	'ubnt_temperature': { labels: [ 'device' ], to: 'ubnt_temperature_celsius', alias: true },
	'ubnt_frequency': { labels: [ 'device' ], to: 'ubnt_frequency_hertz', note: 'In Hz, where it was MHz.' },
	'ubnt_center1_freq': { labels: [ 'device' ], to: 'ubnt_center1_frequency_hertz', note: 'In Hz, where it was MHz.' },
	'ubnt_chanbw': { labels: [ 'device' ], to: 'ubnt_channel_width_hertz', note: 'In Hz, where it was MHz.' },
	'ubnt_signal': { labels: [ 'device' ], to: 'ubnt_signal_dbm', alias: true },
	'ubnt_noisef': { labels: [ 'device' ], to: 'ubnt_noise_floor_dbm', alias: true },
	'ubnt_txpower': { labels: [ 'device' ], to: 'ubnt_transmit_power_dbm', alias: true },
	'ubnt_distance': { labels: [ 'device' ], to: 'ubnt_distance_meters', alias: true },
	'ubnt_txrate': { labels: [ 'device' ], to: 'ubnt_transmit_rate_bits_per_second', note: 'In bit/s, where it was Mbit/s.' },
	'ubnt_rxrate': { labels: [ 'device' ], to: 'ubnt_receive_rate_bits_per_second', note: 'In bit/s, where it was Mbit/s.' },
	'ubnt_throughput_tx': { labels: [ 'device' ], to: 'ubnt_transmit_throughput_bits_per_second', note: 'In bit/s, where it was kbit/s.' },
	'ubnt_throughput_rx': { labels: [ 'device' ], to: 'ubnt_receive_throughput_bits_per_second', note: 'In bit/s, where it was kbit/s.' },
	'ubnt_polling_cb_capacity': { labels: [ 'device' ], to: 'ubnt_airmax_combined_capacity_bits_per_second', note: 'In bit/s, where it was kbit/s.' },
	'ubnt_polling_dl_capacity': { labels: [ 'device' ], to: 'ubnt_airmax_downlink_capacity_bits_per_second', note: 'In bit/s, where it was kbit/s.' },
	'ubnt_polling_ul_capacity': { labels: [ 'device' ], to: 'ubnt_airmax_uplink_capacity_bits_per_second', note: 'In bit/s, where it was kbit/s.' },
	'ubnt_use': { labels: [ 'device' ], to: 'ubnt_airtime_use', alias: true },
	'ubnt_tx_use': { labels: [ 'device' ], to: 'ubnt_transmit_airtime_use', alias: true },
	'ubnt_rx_use': { labels: [ 'device' ], to: 'ubnt_receive_airtime_use', alias: true },
	'ubnt_count': { labels: [ 'device' ], to: 'ubnt_stations', alias: true },
	'ubnt_aprepeater': { labels: [ 'device' ], to: 'ubnt_ap_repeater', alias: true },
	'ubnt_rstatus': { labels: [ 'device' ], to: 'ubnt_radio_status', alias: true },
	'ubnt_loadavg': { labels: [ 'device' ], to: 'ubnt_loadavg' },
	'ubnt_channel': { labels: [ 'device' ], to: 'ubnt_channel' },
	'ubnt_band': { labels: [ 'device' ], to: 'ubnt_band' },
	'ubnt_dfs': { labels: [ 'device' ], to: 'ubnt_dfs' },
	'ubnt_rssi': { labels: [ 'device' ], to: 'ubnt_rssi' },
	'ubnt_rx_chainmask': { labels: [ 'device' ], to: 'ubnt_rx_chainmask' },
	'ubnt_tx_chainmask': { labels: [ 'device' ], to: 'ubnt_tx_chainmask' },
	'ubnt_cac_state': { labels: [ 'device' ], to: 'ubnt_cac_state' },
	'ubnt_cac_timeout': { labels: [ 'device' ], to: 'ubnt_cac_timeout' },
	'ubnt_rx_idx': { labels: [ 'device' ], to: 'ubnt_rx_idx' },
	'ubnt_rx_nss': { labels: [ 'device' ], to: 'ubnt_rx_nss' },
	'ubnt_tx_idx': { labels: [ 'device' ], to: 'ubnt_tx_idx' },
	'ubnt_tx_nss': { labels: [ 'device' ], to: 'ubnt_tx_nss' },
	'ubnt_atpc_status': { labels: [ 'device' ], to: 'ubnt_atpc_status' },

	// ---- uci_dhcp_host ----
	'uci_dhcp_host': { labels: [ 'name', 'dns', 'ip', 'duid', 'mac' ], to: 'node_openwrt_dhcp_host_info', note: 'In OpenWrt\'s namespace, as the ucode exporter\'s `dhcp_host_info`, labeled `name`, `mac` and `ip`: `dns` and `duid` are not written.' },
	'dhcp_host_info': { labels: [ 'name', 'mac', 'ip' ], to: 'node_openwrt_dhcp_host_info', alias: true, note: 'In OpenWrt\'s namespace.' },

	// ---- unbound ----
	'unbound_num_queries_total': { labels: [], to: 'unbound_queries_total', note: 'Per thread, `thread`, as letsencrypt/unbound_exporter writes it, where it was the `total.*` sum: `sum without (thread)` is the old value. So are the other counters and request list gauges below.' },
	'unbound_num_queries_ip_ratelimited_total': { labels: [], to: 'unbound_queries_ip_ratelimited_total', note: 'Per thread.' },
	'unbound_num_queries_cookie_valid_total': { labels: [], to: 'unbound_queries_cookie_valid_total', note: 'Per thread.' },
	'unbound_num_queries_cookie_client_total': { labels: [], to: 'unbound_queries_cookie_client_total', note: 'Per thread.' },
	'unbound_num_queries_cookie_invalid_total': { labels: [], to: 'unbound_queries_cookie_invalid_total', note: 'Per thread.' },
	'unbound_num_queries_discard_timeout_total': { labels: [], to: 'unbound_queries_discard_timeout_total', note: 'Per thread.' },
	'unbound_num_queries_wait_limit_total': { labels: [], to: 'unbound_queries_wait_limit_total', note: 'Per thread.' },
	'unbound_cachehits_total': { labels: [], to: 'unbound_cache_hits_total', note: 'Per thread.' },
	'unbound_cachemiss_total': { labels: [], to: 'unbound_cache_misses_total', note: 'Per thread.' },
	'unbound_prefetch_total': { labels: [], to: 'unbound_prefetches_total', note: 'Per thread.' },
	'unbound_num_queries_timed_out_total': { labels: [], to: 'unbound_queries_timed_out_total', note: 'Per thread.' },
	'unbound_query_queue_time_us_max': { labels: [], to: 'unbound_query_queue_time_seconds_max', note: 'Per thread, in seconds where it was µs.' },
	'unbound_num_expired_total': { labels: [], to: 'unbound_expired_total', note: 'Per thread.' },
	'unbound_num_recursivereplies_total': { labels: [], to: 'unbound_recursive_replies_total', note: 'Per thread.' },
	'unbound_num_dns_error_reports_total': { labels: [], to: 'unbound_dns_error_reports_total', note: 'Per thread.' },
	'unbound_requestlist_avg': { labels: [], to: 'unbound_request_list_avg', note: 'Per thread.' },
	'unbound_requestlist_max': { labels: [], to: 'unbound_request_list_max', note: 'Per thread.' },
	'unbound_requestlist_overwritten_total': { labels: [], to: 'unbound_request_list_overwritten_total', note: 'Per thread.' },
	'unbound_requestlist_exceeded_total': { labels: [], to: 'unbound_request_list_exceeded_total', note: 'Per thread.' },
	'unbound_requestlist_current_all': { labels: [], to: 'unbound_request_list_current_all', note: 'Per thread.' },
	'unbound_requestlist_current_user': { labels: [], to: 'unbound_request_list_current_user', note: 'Per thread.' },
	'unbound_recursion_time_avg': { labels: [], to: 'unbound_recursion_time_seconds_avg', alias: true },
	'unbound_recursion_time_median': { labels: [], to: 'unbound_recursion_time_seconds_median', alias: true },

	// ---- wifi, wifi_stations ----
	'wifi_radio_info': { labels: [ 'radio', 'htmode', 'channel', 'country' ], to: 'node_wifi_radio_info', alias: true, note: 'node_exporter\'s `node_wifi_` namespace.' },
	'wifi_network_info': { labels: [ 'radio', 'ifname', 'ssid', 'bssid', 'mode' ], to: 'node_wifi_network_info', note: '`ifname` is `device`, as node_exporter names it.' },
	'wifi_network_quality': { labels: { lua: [ 'device', 'ifname', 'ssid', 'bssid', 'mode', 'channel', 'country', 'frequency' ], ucode: [ 'radio', 'ifname' ] }, to: 'node_wifi_network_quality_ratio', note: 'A ratio of 0 to 1, where it was a percentage. The Lua exporter\'s `device` was the radio, `radio` here, and `ifname` the interface, `device` here; the network\'s names are on `node_wifi_network_info`, the radio\'s on `node_wifi_radio_info`.' },
	'wifi_network_bitrate': { labels: { lua: [ 'device', 'ifname', 'ssid', 'bssid', 'mode', 'channel', 'country', 'frequency' ], ucode: [ 'radio', 'ifname' ] }, to: 'node_wifi_network_transmit_bits_per_second', note: 'In bit/s, where it was kbit/s. Labels as `wifi_network_quality`.' },
	'wifi_network_noise_dbm': { labels: { lua: [ 'device', 'ifname', 'ssid', 'bssid', 'mode', 'channel', 'country', 'frequency' ], ucode: [ 'radio', 'ifname' ] }, to: 'node_wifi_network_noise_dbm', note: 'Labels as `wifi_network_quality`.' },
	'wifi_network_signal_dbm': { labels: { lua: [ 'device', 'ifname', 'ssid', 'bssid', 'mode', 'channel', 'country', 'frequency' ], ucode: [ 'radio', 'ifname' ] }, to: 'node_wifi_network_signal_dbm', note: 'Labels as `wifi_network_quality`.' },
	'wifi_stations': { labels: [ 'ifname' ], to: 'node_wifi_stations', note: 'wifi\'s, with its option `stations`; `ifname` is `device`, and `radio` is added.' },
	'wifi_stations_total': { labels: [ 'radio', 'ifname' ], to: 'node_wifi_stations', note: 'A gauge: the stations associated now. `ifname` is `device`.' },
	'wifi_station_signal_dbm': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_signal_dbm', note: '`ifname` is `device` and `mac` is `mac_address`, as node_exporter names them; the Lua exporter\'s had no `radio`.' },
	'wifi_station_inactive_milliseconds': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_inactive_seconds', note: 'In seconds. Labels as `wifi_station_signal_dbm`.' },
	'wifi_station_expected_throughput_kilobits_per_second': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_expected_throughput_bits_per_second', note: 'In bit/s. Labels as `wifi_station_signal_dbm`.' },
	'wifi_station_transmit_kilobits_per_second': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_transmit_bits_per_second', note: 'In bit/s. Labels as `wifi_station_signal_dbm`.' },
	'wifi_station_receive_kilobits_per_second': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_receive_bits_per_second', note: 'In bit/s. Labels as `wifi_station_signal_dbm`.' },
	'wifi_station_transmit_packets_total': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_transmitted_packets_total', note: 'Labels as `wifi_station_signal_dbm`.' },
	'wifi_station_receive_packets_total': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_received_packets_total', note: 'Labels as `wifi_station_signal_dbm`.' },
	'wifi_station_transmit_bytes_total': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_transmit_bytes_total', note: 'Labels as `wifi_station_signal_dbm`.' },
	'wifi_station_receive_bytes_total': { labels: { lua: [ 'ifname', 'mac' ], ucode: [ 'radio', 'ifname', 'mac' ] }, to: 'node_wifi_station_receive_bytes_total', note: 'Labels as `wifi_station_signal_dbm`.' },

	// ---- wireguard ----
	'wireguard_interface_info': { labels: [ 'name', 'public_key', 'listen_port', 'fwmark' ], to: 'wireguard_interface_info', note: '`name` is `interface`, as in the other families; an unset fwmark is left out, not `NaN`.' },
	'wireguard_peer_info': { labels: [ 'interface', 'public_key', 'description', 'endpoint', 'persistent_keepalive_interval' ], to: 'wireguard_peer_info', note: '`description` is `friendly_name`, and only with the collector\'s option `peer_names`; an unset keepalive is left out, not `NaN`.' },
	'wireguard_latest_handshake_seconds': { labels: [ 'public_key' ], to: 'wireguard_latest_handshake_seconds', note: 'prometheus_wireguard_exporter\'s labels: `interface`, `allowed_ips`, and `friendly_name` with `peer_names`.' },
	'wireguard_received_bytes_total': { labels: [ 'public_key' ], to: 'wireguard_received_bytes_total', note: 'A counter; labels as `wireguard_latest_handshake_seconds`.' },
	'wireguard_sent_bytes_total': { labels: [ 'public_key' ], to: 'wireguard_sent_bytes_total', note: 'A counter; labels as `wireguard_latest_handshake_seconds`.' },
};
