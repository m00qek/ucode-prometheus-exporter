'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/hostapd_stations.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's hostapd_stations collector, from hostapd's ubus objects
// where Lua ran hostapd_cli: for each network.wireless interface with a
// hostapd.<ifname> object, its get_status (ssid, bssid, freq, channel) and the
// clients of get_clients. Each station's series are labelled by what tells it
// apart, {vif, station}; what Lua labelled every series with as well, the
// network's ssid, bssid, encryption, frequency and channel, is on one
// hostapd_station_info per station, so a channel change (DFS, ACS) starts no
// new series of its counters.
//
// A counter get_clients does not give a station is left out, not written as a
// 0, which a dashboard would take for a reset.
//
// get_clients has no connected time, inactive time, SAE group or short
// preamble flag, so hostapd_station_connected_seconds_total,
// hostapd_station_inactive_seconds, hostapd_station_sae_group and
// hostapd_station_flag_short_preamble are not written. The VHT beamformee
// flags come from the capabilities hostapd parses, not from vht_caps_info.
//
// An interface whose hostapd object does not answer is left out, and fails the
// collector once the others are written.

import { Result, errors, services, u32 } from 'prometheus_exporter.api';

export const meta = {
	name: 'hostapd_stations',
	title: 'hostapd stations',
	help: 'Stations of each hostapd access point, from hostapd\'s ubus objects.',
	needs: [ 'ubus' ],
};

function metrics(out) {
	return {
		info: out.gauge('hostapd_station_info', 'A station of an access point, and the network it is on: its SSID, BSSID, encryption, frequency and channel.'),
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
		labels: out.labels,
	};
}

// hostapd sends the packet counts with blobmsg_add_u32() (src/ap/ubus.c),
// which ucode's ubus gives signed (u32); the byte counts are 64-bit. A count
// it does not send is null, which writes no sample.
function station(m, labels, c) {
	m.rx_packets(labels, u32(c.packets?.rx));
	m.rx_bytes(labels, c.bytes?.rx);
	m.tx_packets(labels, u32(c.packets?.tx));
	m.tx_bytes(labels, c.bytes?.tx);
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
		m.info({
			vif: iface.ifname,
			station: mac,
			ssid: status.ssid,
			bssid: status.bssid,
			encryption: iface.config?.encryption,
			frequency: status.freq,
			channel: status.channel,
		}, 1);
		station(m, m.labels({ vif: iface.ifname, station: mac }), c ?? {});
	}

	return null;
}

// A device without radios (no network.wireless object, or one without radios)
// or without a hostapd object for any of their interfaces has nothing to
// observe.
export function collect(deps, out) {
	let res = deps.ubus.list();

	if (!res.ok)
		return res;

	let objects = res.data;
	res = deps.ubus.call('network.wireless', 'status');
	if (services.object_missing(res))
		return Result.none('no wireless radios');
	if (!res.ok)
		return res;

	let status = res.data;
	if (type(status) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'network.wireless status: not an object');
	if (!length(status))
		return Result.none('no wireless radios');

	let served = [];

	for (let radio, r in status)
		for (let iface in r?.interfaces ?? [])
			if (type(iface?.ifname) == 'string' && `hostapd.${iface.ifname}` in objects)
				push(served, iface);

	if (!length(served))
		return Result.none('no hostapd access points');

	let m = metrics(out);
	let failure = null;

	for (let iface in served) {
		let fail = access_point(deps.ubus, m, iface);
		failure ??= fail;
	}

	return failure ?? Result.ok();
};
