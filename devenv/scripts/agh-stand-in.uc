'use strict';

// AdGuard Home's HTTP API as the agh collector asks it, for make e2e:
//   ucode agh-stand-in.uc PORT DIR
// listens on 127.0.0.1:PORT and answers each GET of /control/<name> with
// DIR/127.0.0.1_8080.control_<name>.txt, a fixture set's capture of the
// router's replies (HTTP head and body), one request a connection, until it
// is killed. Anything else is a 404.

import * as socket from 'socket';
import { readfile } from 'fs';

const NOT_FOUND = 'HTTP/1.0 404 Not Found\r\nContent-Type: text/plain\r\n\r\n404 page not found\n';

let port = int(ARGV[0]);
let dir = ARGV[1];
let srv = socket.create(socket.AF_INET, socket.SOCK_STREAM);

srv.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);
if (!srv.bind({ family: socket.AF_INET, address: '127.0.0.1', port }) || !srv.listen(8))
	die(`agh-stand-in: 127.0.0.1:${port}: ${socket.error()}\n`);

function reply_to(req) {
	let path = split(split(req, '\r\n')[0], ' ')[1] ?? '';

	if (!match(path, /^\/control\/[a-z_]+$/))
		return NOT_FOUND;

	return readfile(`${dir}/127.0.0.1_8080.${replace(substr(path, 1), '/', '_')}.txt`) ?? NOT_FOUND;
}

while (true) {
	let c = srv.accept();

	if (!c)
		continue;

	let req = '';

	while (index(req, '\r\n\r\n') < 0) {
		let chunk = c.recv(1024);

		if (chunk == null || chunk == '')
			break;
		req += chunk;
	}

	c.send(reply_to(req));
	c.close();
}
