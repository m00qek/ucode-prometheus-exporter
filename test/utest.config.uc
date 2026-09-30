// utest config (modeled on wgpathd's). Tests build `deps` from these mocks'
// proxies (see context.uc), so a module's whole import subgraph sees the fakes.
return {
	pattern: '*_test.uc',
	lib_paths: [ '.', '../src' ],
	mocks: {
		fs:      null,
		uci:     null,
		ubus:    { proxy: 'proxies/ubus.uc' },
		nl80211: { proxy: 'proxies/nl80211.uc' },
	},
};
