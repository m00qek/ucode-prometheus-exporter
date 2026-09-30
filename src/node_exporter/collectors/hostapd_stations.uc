'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/hostapd_stations.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's hostapd_stations collector, from hostapd's ubus objects
// where Lua ran hostapd_cli: for each network.wireless interface with a
// hostapd.<ifname> object, its get_status (ssid, bssid, freq, channel) and the
// clients of get_clients, labelled as Lua did: {vif, ssid, bssid, encryption,
// frequency, channel, station}.
//
// get_clients has no connected time, inactive time, SAE group or short
// preamble flag, so hostapd_station_connected_seconds_total,
// hostapd_station_inactive_seconds, hostapd_station_sae_group and
// hostapd_station_flag_short_preamble are not written. The VHT beamformee
// flags come from the capabilities hostapd parses, not from vht_caps_info.
//
// An interface whose hostapd object does not answer is left out, and fails the
// collector once the others are written.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'hostapd_stations',
	help: 'Stations of each hostapd access point, from hostapd\'s ubus objects.',
	needs: [ 'ubus' ],
};

function metrics(out) {
	return {
		rx_packets: out.counter('hostapd_station_receive_packets_total', 'Packets received from the station.'),
		rx_bytes: out.counter('hostapd_station_receive_bytes_total', 'Bytes received from the station.'),
		tx_packets: out.counter('hostapd_station_transmit_packets_total', 'Packets transmitted to the station.'),
		tx_bytes: out.counter('hostapd_station_transmit_bytes_total', 'Bytes transmitted to the station.'),
		signal: out.gauge('hostapd_station_signal_dbm', 'Signal of the station, in dBm.'),
		flag_auth: out.gauge('hostapd_station_flag_auth', 'Whether the station is authenticated.'),
		flag_assoc: out.gauge('hostapd_station_flag_assoc', 'Whether the station is associated.'),
		flag_ht: out.gauge('hostapd_station_flag_ht', 'Whether the station uses HT (802.11n).'),
		flag_vht: out.gauge('hostapd_station_flag_vht', 'Whether the station uses VHT (802.11ac).'),
		flag_he: out.gauge('hostapd_station_flag_he', 'Whether the station uses HE (802.11ax).'),
		flag_mfp: out.gauge('hostapd_station_flag_mfp', 'Whether the station uses management frame protection.'),
		flag_wmm: out.gauge('hostapd_station_flag_wmm', 'Whether the station uses WMM.'),
		vht_su_beamformee: out.gauge('hostapd_station_vht_capb_su_beamformee', 'Whether the station is a VHT single-user beamformee.'),
		vht_mu_beamformee: out.gauge('hostapd_station_vht_capb_mu_beamformee', 'Whether the station is a VHT multi-user beamformee.'),
	};
}

function station(m, labels, c) {
	m.rx_packets(labels, c.packets?.rx ?? 0);
	m.rx_bytes(labels, c.bytes?.rx ?? 0);
	m.tx_packets(labels, c.packets?.tx ?? 0);
	m.tx_bytes(labels, c.bytes?.tx ?? 0);
	m.signal(labels, c.signal);

	m.flag_auth(labels, !!c.auth);
	m.flag_assoc(labels, !!c.assoc);
	m.flag_ht(labels, !!c.ht);
	m.flag_vht(labels, !!c.vht);
	m.flag_he(labels, !!c.he);
	m.flag_mfp(labels, !!c.mfp);
	m.flag_wmm(labels, !!c.wmm);

	m.vht_su_beamformee(labels, !!c.capabilities?.vht?.su_beamformee);
	m.vht_mu_beamformee(labels, !!c.capabilities?.vht?.mu_beamformee);
}

// One interface's samples; null, or the Result of the call that failed.
function access_point(ubus, m, iface) {
	let object = `hostapd.${iface.ifname}`;
	let res = ubus.call(object, 'get_status');

	if (!res.ok)
		return res;

	let status = res.data ?? {};
	res = ubus.call(object, 'get_clients');
	if (!res.ok)
		return res;

	for (let mac, c in res.data?.clients ?? {}) {
		station(m, {
			vif: iface.ifname,
			ssid: status.ssid,
			bssid: status.bssid,
			encryption: iface.config?.encryption,
			frequency: status.freq,
			channel: status.channel,
			station: mac,
		}, c ?? {});
	}

	return null;
}

export function collect(deps, out) {
	let res = deps.ubus.list();

	if (!res.ok)
		return res;

	let objects = res.data;
	res = deps.ubus.call('network.wireless', 'status');
	if (!res.ok)
		return res;

	let status = res.data;
	if (type(status) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'network.wireless status: not an object');

	let m = metrics(out);
	let failure = null;

	for (let radio, r in status) {
		for (let iface in r?.interfaces ?? []) {
			if (type(iface?.ifname) != 'string' || !(`hostapd.${iface.ifname}` in objects))
				continue;

			let fail = access_point(deps.ubus, m, iface);
			failure ??= fail;
		}
	}

	return failure ?? Result.ok();
};
