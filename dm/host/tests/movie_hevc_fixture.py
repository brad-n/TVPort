#!/usr/bin/env python3
"""Writes movie_hevc_fixture.h for t_movie_hevc.c: a short AV1 clip and the HEVC sidecar pack dm/tools/movie_hevc.py makes of it, as byte arrays. No game data.
The clip: ffmpeg's testsrc2, 96x64 at 60 fps, 24 pictures, SVT-AV1 (preset 8, CRF 40, a key frame every 12 pictures and its hierarchical structure, so it has units that only show a frame
decoded earlier, 3 bytes each and alike), in WebM for the pack and as IVF for the test (a 12-byte header before each unit; ffmpeg puts a temporal delimiter in front of each, which the
host's key leaves out, as a demuxer may). Needs ffmpeg with libsvtav1, libdav1d and hevc_videotoolbox (Homebrew's). Run it from anywhere: python3 dm/host/tests/movie_hevc_fixture.py"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools'))
import movie_hevc

FRAMES, KEYINT, QUALITY = 24, 12, 50


def array(name, data):
    rows = [', '.join(f'0x{b:02x}' for b in data[i:i + 24]) for i in range(0, len(data), 24)]
    return f'static const uint8_t {name}[{len(data)}] = {{\n' + ',\n'.join('    ' + r for r in rows) + '\n};\n'


def main():
    ffmpeg = movie_hevc.find_ffmpeg()
    if not ffmpeg:
        sys.exit('ffmpeg was not found')
    work = tempfile.mkdtemp(prefix='movie_hevc_fixture.')
    try:
        movies = os.path.join(work, 'romfs', 'Movie')
        os.makedirs(movies)
        webm = os.path.join(movies, 'clip.webm')
        subprocess.run([ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', f'testsrc2=size=96x64:rate=60', '-frames:v', str(FRAMES), '-pix_fmt', 'yuv420p',
                        '-c:v', 'libsvtav1', '-preset', '8', '-crf', '40', '-g', str(KEYINT), '-svtav1-params', f'keyint={KEYINT}:scd=0', '-color_primaries', 'bt709',
                        '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv', webm], check=True, stderr=subprocess.DEVNULL)   # SVT-AV1 prints its settings whatever -v says
        ivf = os.path.join(work, 'clip.ivf')
        subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', webm, '-c', 'copy', ivf], check=True)
        report = movie_hevc.build(os.path.join(work, 'romfs'), os.path.join(work, 'out'), quality=QUALITY, workers=1)
        assert report['converted'] == 1 and report['pictures'] == FRAMES, report
        with open(ivf, 'rb') as f:
            ivf_bytes = f.read()
        with open(os.path.join(work, 'out', movie_hevc.PACK), 'rb') as f:
            pack = f.read()
        out = os.path.join(HERE, 'movie_hevc_fixture.h')
        with open(out, 'w') as f:
            f.write(f'// Made by movie_hevc_fixture.py ({report["ffmpeg"].split(" Copyright")[0]}): testsrc2 96x64, {FRAMES} pictures at 60 fps, SVT-AV1 with a key frame every {KEYINT},\n'
                    f'// as IVF (fixture_ivf), and the HEVC sidecar pack of its WebM (fixture_pack, {report["hevc_bytes"]} bytes of HEVC at quality {report["quality"]})\n')
            f.write('#pragma once\n#include <stdint.h>\n')
            f.write(f'enum {{ FIXTURE_FRAMES = {FRAMES}, FIXTURE_KEYINT = {KEYINT} }};\n')
            f.write(array('fixture_ivf', ivf_bytes))
            f.write(array('fixture_pack', pack))
        print(f'{out}: {len(ivf_bytes)} bytes of IVF, {len(pack)} bytes of pack')
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    main()
