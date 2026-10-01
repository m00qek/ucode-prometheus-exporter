'use strict';

// rpcd's rc object, as a ubus mock's data: rc({ dnsmasq: true, unbound: false })
// answers `rc list { name }` as 25.12's rpcd does, { <name>: { start, enabled } }
// for an init script the map names (enabled or not), {} for any other, which is
// not installed. Merge it into a mock's data: { ...rc({...}), 'dnsmasq:metrics': ... }.

export function list(scripts) {
	return function(args) {
		let name = args?.name;

		return (name in keys(scripts)) ? { [name]: { start: 19, enabled: scripts[name] } } : {};
	};
};

export function rc(scripts) {
	return { 'rc:list': list(scripts) };
};
