// Derive a synthetic QuickTime v2 LPCM/reflection fixture. No personal media.
// Run from repository root with Node.js. Input was generated with ffmpeg.
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
const root = 'app/android/app/src/androidTest/assets/';
// Use dimensions supported by physical phone AVC encoders (96x64 is too small).
execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', root + 'iphone_live.mov',
  '-vf', 'scale=192:128', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '18',
  '-c:a', 'copy', root + 'iphone_transform.mov']);
const input = fs.readFileSync(root + 'iphone_transform.mov');
function boxes(b) {
  const out = [];
  for (let p = 0; p < b.length;) {
    const n = b.readUInt32BE(p);
    if (n < 8 || p + n > b.length) throw Error('Invalid fixture');
    out.push(b.subarray(p, p + n)); p += n;
  }
  return out;
}
function box(type, body) {
  const header = Buffer.alloc(8); header.writeUInt32BE(body.length + 8); header.write(type, 4);
  return Buffer.concat([header, body]);
}
function rewrite(b) {
  const type = b.toString('ascii', 4, 8);
  if (['moov','trak','mdia','minf','stbl'].includes(type))
    return box(type, Buffer.concat(boxes(b.subarray(8)).map(rewrite)));
  if (type === 'tkhd' && b.readUInt32BE(20) === 1) {
    const out = Buffer.from(b);
    // EXIF 7 equivalent: x' = -y + height, y' = -x + width.
    [0,-65536,0,-65536,0,0,128*65536,192*65536,0x40000000]
      .forEach((v, i) => out.writeInt32BE(v, 48 + i * 4));
    return out;
  }
  if (type === 'stsd' && b.toString('ascii', 20, 24) === 'sowt') {
    const entry = Buffer.alloc(72);
    entry.writeUInt32BE(72); entry.write('lpcm', 4); entry.writeUInt16BE(1, 14);
    entry.writeUInt16BE(2, 16); entry.writeUInt16BE(3, 24); entry.writeUInt16BE(16, 26);
    entry.writeUInt16BE(0xfffe, 28); entry.writeUInt32BE(65536, 32);
    entry.writeUInt32BE(72, 36); entry.writeDoubleBE(44100, 40);
    entry.writeUInt32BE(1, 48); entry.writeUInt32BE(0x7f000000, 52);
    entry.writeUInt32BE(16, 56); entry.writeUInt32BE(12, 60);
    entry.writeUInt32BE(2, 64); entry.writeUInt32BE(1, 68);
    return box(type, Buffer.concat([b.subarray(8, 16), entry]));
  }
  return b;
}
const top = boxes(input);
if (top.findIndex(b => b.toString('ascii',4,8)==='moov') <
    top.findIndex(b => b.toString('ascii',4,8)==='mdat')) throw Error('Needs moov-last fixture');
fs.writeFileSync(root + 'iphone_lpcm_mirror.mov', Buffer.concat(top.map(rewrite)));
