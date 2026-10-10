// utest config (modeled on wgpathd's). Tests build `deps` from these mocks'
// proxies (see prometheus.exporter.devkit.collector), so a module's whole
// import subgraph sees the fakes. The devkit's template collector package is
// tested with the rest, its module on the path as its own config puts it.
return {
	pattern: '*_test.uc',
	lib_paths: [ '.', '../src', '../devenv/scripts', '../devkit/template/src' ],
	mocks: {
		fs:      null,
		uci:     null,
		ubus:    { proxy: '../src/prometheus/exporter/devkit/proxies/ubus.uc' },
		rtnl:    { proxy: '../src/prometheus/exporter/devkit/proxies/rtnl.uc' },
		nl80211: { proxy: '../src/prometheus/exporter/devkit/proxies/nl80211.uc' },
		socket:  { proxy: '../src/prometheus/exporter/devkit/proxies/socket.uc' },
	},
};
