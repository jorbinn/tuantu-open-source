"""Regenerate synthetic media. Requires ffmpeg and Node.js on PATH."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / 'app/android/app/src/androidTest/assets'
FLUTTER = ROOT / 'app/test/fixtures/live'
NATIVE.mkdir(parents=True, exist_ok=True)
FLUTTER.mkdir(parents=True, exist_ok=True)


def ffmpeg(*args):
    subprocess.run(['ffmpeg', '-y', '-v', 'error', *map(str, args)], check=True, cwd=ROOT)


ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=96x64:rate=25', '-t', '1',
       '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
       '-map_metadata', '-1', '-movflags', '+faststart', FLUTTER / 'sample.mp4')
ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=96x64:rate=25',
       '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100', '-t', '0.8',
       '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
       '-c:a', 'pcm_s16le', '-map_metadata', '-1', NATIVE / 'iphone_live.mov')
subprocess.run(['node', 'scripts/make_live_lpcm_fixture.mjs'], cwd=ROOT, check=True)
print('Generated synthetic patterns and sine-wave media; no camera/recording inputs')
