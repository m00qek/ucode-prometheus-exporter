'use strict';

import { Result, errors, u32 } from 'prometheus.exporter';

export const meta = {
	name: 'hostapd_stations',
	title: 'hostapd stations',
	help: 'Stations of each hostapd access point, from hostapd\'s ubus objects.',
	needs: [ 'ubus' ],
	ubus: { 'hostapd.*': [ 'get_clients', 'get_status' ], 'prometheus-exporter': [ 'wireless' ] },
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

export function collect(deps, out) {
	let res = deps.ubus.list();

	if (!res.ok)
		return res;

	let objects = res.data;
	res = deps.ubus.call('prometheus-exporter', 'wireless');
	if (!res.ok)
		return res;

	let status = res.data?.radios;
	if (type(status) != 'object')
		return Result.err(errors.SOURCE_INVALID, `prometheus-exporter wireless: ${res.data?.message ?? 'no radios'}`);
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
