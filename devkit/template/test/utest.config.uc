// utest's config for the collector's tests, on the exporter's devkit
// (ucode-prometheus-exporter-devkit): the collector's module on the path,
// and the mocks with_collector builds its capabilities from, ubus, rtnl,
// nl80211 and socket with the devkit's proxies. Run from the package's
// directory: utest -c test/utest.config.uc test
return {
	pattern: '*_test.uc',
	lib_paths: [ '../src' ],
	mocks: {
		fs:      null,
		uci:     null,
		ubus:    { proxy: '/usr/share/ucode/prometheus_exporter/devkit/proxies/ubus.uc' },
		rtnl:    { proxy: '/usr/share/ucode/prometheus_exporter/devkit/proxies/rtnl.uc' },
		nl80211: { proxy: '/usr/share/ucode/prometheus_exporter/devkit/proxies/nl80211.uc' },
		socket:  { proxy: '/usr/share/ucode/prometheus_exporter/devkit/proxies/socket.uc' },
	},
};
