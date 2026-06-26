// Generates placeholder PWA icons (solid background + no external deps).
// Run: node scripts/generate-icons.mjs — replace with branded icons later.
import { deflateSync } from 'node:zlib';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, '..', 'static', 'icons');
mkdirSync(outDir, { recursive: true });

// zinc-950 (#09090b), matching the manifest theme color.
const [r, g, b] = [0x09, 0x09, 0x0b];

function crc32(buf) {
	let crc = ~0;
	for (const byte of buf) {
		crc ^= byte;
		for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
	}
	return ~crc >>> 0;
}

function chunk(type, data) {
	const len = Buffer.alloc(4);
	len.writeUInt32BE(data.length);
	const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
	const crc = Buffer.alloc(4);
	crc.writeUInt32BE(crc32(body));
	return Buffer.concat([len, body, crc]);
}

function solidPng(size) {
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(size, 0);
	ihdr.writeUInt32BE(size, 4);
	ihdr[8] = 8; // bit depth
	ihdr[9] = 2; // truecolor
	const row = Buffer.concat([Buffer.from([0]), Buffer.alloc(size * 3)]);
	for (let x = 0; x < size; x++) row.set([r, g, b], 1 + x * 3);
	const raw = Buffer.concat(Array.from({ length: size }, () => row));
	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk('IHDR', ihdr),
		chunk('IDAT', deflateSync(raw)),
		chunk('IEND', Buffer.alloc(0))
	]);
}

for (const size of [192, 512]) {
	writeFileSync(join(outDir, `icon-${size}.png`), solidPng(size));
	console.log(`wrote static/icons/icon-${size}.png`);
}
