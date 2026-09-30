'use strict';

// The collectors a scrape's query string asks for: node_exporter's collect[]=
// and exclude[]=, and the plain collect= of the earlier ucode exporter.

function urldecode(s) {
	return replace(replace(s, '+', ' '), /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
}

// { collect, exclude }: names in order, without repeats.
export function parse(query) {
	let collect = [], exclude = [];

	for (let pair in split(query ?? '', '&')) {
		let kv = split(pair, '=', 2);

		if (length(kv) != 2)
			continue;

		let key = urldecode(kv[0]);
		if (key in [ 'collect', 'collect[]' ])
			push(collect, urldecode(kv[1]));
		else if (key == 'exclude[]')
			push(exclude, urldecode(kv[1]));
	}

	return { collect: uniq(collect), exclude: uniq(exclude) };
};
