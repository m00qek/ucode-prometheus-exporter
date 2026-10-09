'use strict';

// make failure-demo's busy router, in the QEMU guest: N connections in the
// conntrack table, as a NAT router's LAN clients make them. 64 addresses of
// the LAN, which qemu.sh's guest gives br-lan, each send a UDP datagram to
// port 443 of addresses of 198.18.0.0/15 in turn, out of the WAN, which
// leads nowhere: each is a connection the firewall masquerades, in the
// table until nf_conntrack_udp_timeout, which the guest raises to an hour.
// usage: ucode conntrack.uc N

import * as socket from 'socket';

const n = +ARGV[0];
const HOSTS = 64;

let socks = [];

for (let h = 0; h < HOSTS; h++) {
	let s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);

	if (!s || !s.bind({ address: `192.168.1.${100 + h}`, port: 0 }))
		die(`conntrack.uc: ${socket.error()}\n`);
	push(socks, s);
}

for (let i = 0; i < n; i++)
	socks[i % HOSTS].send('x', 0, { address: `198.18.${int(i / 250)}.${i % 250 + 1}`, port: 443 });
