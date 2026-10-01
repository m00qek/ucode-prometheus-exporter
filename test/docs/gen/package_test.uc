'use strict';

import { describe, it, assert } from 'utest';
import { readfile } from 'fs';
import * as package from 'docs_gen.package';

const MAKEFILE = join('\n', [
	'PKG_NAME:=ucode-prometheus-exporter',
	'PKG_VERSION:=0.2.0',
	'PKG_RELEASE:=3',
	'BASE_COLLECTORS:=cpu loadavg',
	'$(eval $(call Collector,ltq_dsl,ltq-dsl,Lantiq DSL line,))',
	'$(eval $(call Collector,ethtool,ethtool,network driver statistics,+ethtool))',
	'$(eval $(call Collector,wifi,wifi,Wi-Fi,+ucode-mod-nl80211 +iw))',
	'NETWORK_GROUP:=ethtool',
	'WIRELESS_GROUP:=wifi',
	'FULL_GROUP:=$(NETWORK_GROUP) $(WIRELESS_GROUP) ltq-dsl',
	'$(eval $(call Group,network,network statistics,$(NETWORK_GROUP)))',
	'$(eval $(call Group,full,a router or access point,$(FULL_GROUP)))',
	'',
]);

describe('docs_gen.package.parse', () => {
	it('reads the version, the base collectors, the subpackages and the groups, with their lists expanded', () => {
		let pkg = package.parse(MAKEFILE);

		assert.match({ name: 'ucode-prometheus-exporter', version: '0.2.0', release: '3', base: [ 'cpu', 'loadavg' ] },
			{ name: pkg.name, version: pkg.version, release: pkg.release, base: pkg.base });
		assert.match({
			ltq_dsl: { name: 'ltq-dsl', what: 'Lantiq DSL line', depends: [] },
			ethtool: { name: 'ethtool', what: 'network driver statistics', depends: [ '+ethtool' ] },
			wifi: { name: 'wifi', what: 'Wi-Fi', depends: [ '+ucode-mod-nl80211', '+iw' ] },
		}, pkg.collectors);
		assert.match([
			{ name: 'network', purpose: 'network statistics', members: [ 'ethtool' ] },
			{ name: 'full', purpose: 'a router or access point', members: [ 'ethtool', 'wifi', 'ltq-dsl' ] },
		], pkg.groups);
	});

	it('agrees with package-info.sh on the real Makefile', () => {
		let pkg = package.parse(readfile(package.MAKEFILE));

		assert.match(true, length(pkg.base) > 0);
		assert.match([ 'full', 'hardware', 'network', 'wireless' ], sort(map(pkg.groups, (g) => g.name)));
		assert.match(true, 'cpu' in pkg.base);
	});
});

describe('docs_gen.package.placement', () => {
	let pkg = package.parse(MAKEFILE);

	it('places a base collector in the base package, with the groups none of which hold it', () => {
		assert.match({ package: 'ucode-prometheus-exporter', base: true, depends: [], groups: [] },
			package.placement(pkg, 'cpu', 'cpu'));
	});

	it('places another in its subpackage, by its name, with its groups', () => {
		assert.match({ package: 'ucode-prometheus-exporter-ltq-dsl', base: false, depends: [], groups: [ 'ucode-prometheus-exporter-full' ] },
			package.placement(pkg, 'ltq_dsl', 'ltq-dsl'));
		assert.match([ 'ucode-prometheus-exporter-network', 'ucode-prometheus-exporter-full' ],
			package.placement(pkg, 'ethtool', 'ethtool').groups);
	});

	it('is null for a collector the Makefile does not package', () => {
		assert.match(null, package.placement(pkg, 'nope', 'nope'));
	});
});
