'use strict';

// make failure-demo's hung daemon: it registers the ubus objects the wifi,
// hostapd and dnsmasq collectors of both exporters call, netifd's
// `network.wireless`, hostapd's `hostapd.wlan0` and dnsmasq's, and at the
// first call it sleeps, never to answer that call or any after it, as a
// daemon stuck in a driver's call or a lock does. ubusd still lists the
// objects, and hands them each call.
// usage: ucode hung.uc

import * as ubus from 'ubus';
import * as uloop from 'uloop';

function hang(req) {
	sleep(86400 * 1000);
}

uloop.init();
let conn = ubus.connect();

conn.publish('network.wireless', {
	status: { call: hang },
});
conn.publish('hostapd.wlan0', {
	get_clients: { call: hang },
	get_status: { call: hang },
});
conn.publish('dnsmasq', {
	metrics: { call: hang },
});

uloop.run();
