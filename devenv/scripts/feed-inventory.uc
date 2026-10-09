#!/usr/bin/ucode
'use strict';

// make feed-inventory: what the packages feed's exporters write and how they
// are packaged, read from their sources (docs_gen.feed), as JSON.
// usage: ucode -L devenv/scripts feed-inventory.uc PACKAGES_DIR SOURCE
//   PACKAGES_DIR  a checkout of openwrt/packages; SOURCE, what it is, as
//                 openwrt/packages@<commit>

import * as fs from 'fs';
import { inventory } from 'docs_gen.feed';

if (length(ARGV) != 2) {
	warn('usage: feed-inventory.uc PACKAGES_DIR SOURCE\n');
	exit(2);
}

print(sprintf('%.J\n', inventory(fs, ARGV[0], ARGV[1])));
