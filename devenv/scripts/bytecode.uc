#!/usr/bin/env ucode
// usage: ucode bytecode.uc FILE
//
// Writes the stripped bytecode in FILE (ucode -c -s) to standard output with
// each function's source offset zeroed. ucode keeps that offset even when it
// strips the debug information, so code that only moved in its file, as when
// a comment above it is removed, compiles to other bytes; with it zeroed, two
// sources that differ only in comments and blank lines give the same bytes.
// The format is ucode's program.c, uc_program_write(): big-endian, each
// vector padded to 4 bytes.
'use strict';

import * as fs from 'fs';

const F_DEBUG = 1, F_SOURCEINFO = 2, F_EXPORTS = 8;
const FN_HAS_EXCEPTIONS = 8, FN_HAS_NAME = 16, FN_HAS_VARDBG = 32, FN_HAS_OFFSETDBG = 64;

const path = ARGV[0] ?? die('usage: ucode bytecode.uc FILE\n');
const bc = fs.readfile(path) ?? die(`${path}: ${fs.error()}\n`);
let at = 0;

function fail(what) {
	die(`${path}: ${what} at offset ${at}\n`);
}

function u32() {
	if (at + 4 > length(bc))
		fail('premature end');
	let n = ((ord(bc, at) << 24) | (ord(bc, at + 1) << 16) | (ord(bc, at + 2) << 8) | ord(bc, at + 3)) & 0xffffffff;
	at += 4;
	return n;
}

function skip(n) {
	if (at + n > length(bc))
		fail('premature end');
	at += n;
}

function padded(n) {
	return n + ((4 - n % 4) % 4);
}

function vector(itemsize) {
	skip(padded(u32() * itemsize));
}

// The interpreter line ucode -c writes first.
if (substr(bc, 0, 2) == '#!')
	at = index(bc, '\n') + 1;

if (u32() != 0x1b756362)
	fail('no ucode bytecode magic');

const flags = u32();

if (flags & (F_DEBUG | F_SOURCEINFO))
	fail('debug information, not stripped (ucode -c -s)');

// The constants: an index of 64-bit offsets, then the data.
skip(u32() * 8);
skip(padded(u32()));

if (flags & F_EXPORTS)
	for (let n = u32(), i = 0; i < n; i++) {
		let len = u32();
		if (len != 0xffffffff)
			skip(padded(len));
	}

let zeroed = [];

for (let n = u32(), i = 0; i < n; i++) {
	let fflags = u32();

	if (fflags & (FN_HAS_NAME | FN_HAS_VARDBG | FN_HAS_OFFSETDBG))
		fail('debug information in a function');

	// nargs and nupvals, u16 each, then the source's index.
	skip(8);
	push(zeroed, at);
	skip(4);
	vector(1);

	if (fflags & FN_HAS_EXCEPTIONS)
		skip(u32() * 16);
}

if (at != length(bc))
	fail('bytes after the last function');

let out = '', from = 0;

for (let z in zeroed) {
	out += substr(bc, from, z - from) + '\0\0\0\0';
	from = z + 4;
}

print(out + substr(bc, from));
