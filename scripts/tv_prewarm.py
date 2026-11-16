#!/usr/bin/env python3
# The Apple TV app's prewarm pipelines, made on this Mac for the TV's GPU (TVPort: tvport/backend.py prewarm_pipelines). They are what the app's prepare step builds before the first
# frame: the prewarm list's R rows' bases with a vertex layout, its M rows' mesh pipelines and its C rows' compute pipelines (Ocarina of Time on the A15: 14,853 lines, 258 s on its
# first start after an install, 3 s on the next). The Mac app's --prebake (build_ipa_from_nsp.py mac_prebake) makes them the same way: this Mac's host runs as the prebuild tool
# (DM_PSO_PREBUILD=tool with DM_PSO_PREBUILD_OUT) on the app's own shader libraries (the iOS ones the TV app ships, which this Mac's Metal loads) and the app's own list, and writes
# each flush period also as a Metal pipelines script; metal-tt compiles those for the TV's GPU (other_gpu_prewarm, -tvos-version-min) into <GPU>-prewarm-<NN>.mtl4a, each with this
# Mac's index of the same period (the same pipelines, so the same keys). Only those files and prewarm.tsv go into the app's pso/ folder, beside the pair archive build_ipa.sh made
# (pso_offline.py --platform tvos); this Mac's own files stay in the work folder.
# No pair base (DM_PSO_PREBUILD_PAIRS=0): the TV app runs without the device's prebuild (DM_PSO_PREBUILD=0, backend.py write_env), and the pairs pso_offline.py leaves to the device
# (function constants: Ocarina of Time 7,199 of the trimmed library's, about 1.3 GB as bases) would only make the app larger; their pipelines are built at their draws, as before.
# Made again only when its key changes (the list, the libraries' stamp, the host, the depth mode, this Mac's system build, the GPUs). An optimization: a failure leaves the app
# without them (a [RED] line, exit 0), and its prepare step builds them before the first frame, as before.
# Usage: tv_prewarm.py --game <title id> --work <build folder> --msl <folder of b-<chain>[.img]> --manifest <the app's pso_manifest.tsv> --shader-map <the app's shader_map.tsv>
#          --bundle <the app's pso folder> --gpu g14p[,…]
import argparse, hashlib, os, re, shutil, subprocess, sys, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts')); sys.path.insert(0, str(REPO / 'dm/games'))
import build_ipa_from_nsp as bn
import game as gamemod
import shader_lib


def arch_name(a): return a if a.startswith('applegpu_') else 'applegpu_' + a


def prewarm_key(arch, gpus, chain, zero, text, host, lib, osversion):
    """The tool's inputs, as mac_prebake keys them, and the TV's GPUs"""
    digest = hashlib.sha256()
    for part in ('tv', arch, ','.join(gpus), chain, 'zero' if zero else 'gl', text, Path(host).read_bytes() if Path(host).is_file() else str(host),
                 (lib / 'inputs.tsv').read_text() if (lib / 'inputs.tsv').is_file() else '', osversion):
        digest.update(part if isinstance(part, bytes) else str(part).encode()); digest.update(b'\0')
    return digest.hexdigest()


def link_into(out, bundle, gpus):
    """The TV GPUs' files and the stamp into the app's pso folder, an earlier build's taken out first. Returns (files, bytes)"""
    for old in bundle.glob('*-prewarm-*'): old.unlink()
    (bundle / 'prewarm.tsv').unlink(missing_ok=True)
    if not out.is_dir(): return 0, 0
    files = [f for f in sorted(out.iterdir()) if any(f.name.startswith(f'{g}-prewarm-') for g in gpus) and f.suffix in ('.mtl4a', '.keys')]
    if not any(f.suffix == '.mtl4a' for f in files): return 0, 0
    for f in files + [out / 'prewarm.tsv']:
        if not f.is_file(): continue
        try: os.link(f, bundle / f.name)
        except OSError: shutil.copyfile(f, bundle / f.name)
    made = [f for f in files if f.suffix == '.mtl4a']
    return len(made), sum(f.stat().st_size for f in made)


def main(argv=None):
    ap = argparse.ArgumentParser(description='The Apple TV app\'s prewarm pipelines, made on this Mac for the TV\'s GPU')
    ap.add_argument('--game', required=True); ap.add_argument('--work', required=True, type=Path); ap.add_argument('--msl', required=True, type=Path)
    ap.add_argument('--manifest', required=True, type=Path); ap.add_argument('--shader-map', required=True, type=Path); ap.add_argument('--bundle', required=True, type=Path)
    ap.add_argument('--gpu', required=True, help='the TV GPU architectures, comma-separated, with or without the applegpu_ prefix')
    a = ap.parse_args(argv)
    env, work, logs = dict(os.environ), a.work, a.work / 'logs'
    gpus = sorted({arch_name(g.strip()) for g in a.gpu.split(',') if g.strip() and g.strip() != 'none'})
    if not gpus or not a.bundle.is_dir() or not any((a.bundle / f'{g}.mtl4a').is_file() for g in gpus):
        bn.say('prewarm pipelines: none (no pipeline archive for the TV in the app)'); return 0
    text = a.manifest.read_text() if a.manifest.is_file() else ''
    rows = sum(ln.startswith(('R\t', 'M\t', 'C\t')) for ln in text.splitlines())
    if not rows: bn.say(f'prewarm pipelines: none ({a.manifest} has no R, M or C rows)'); return 0
    g = gamemod.load(a.game)
    chain = bn.chain_of(REPO); zero = g.get('depth_mode', 'gl') == 'zero'
    lib = shader_lib.view(a.msl / f'b-{chain}')
    out, stage, keyf = work / 'build/ios/pso/tv-prewarm', work / 'build/ios/pso/tv-prewarm-work', work / 'build/ios/pso/tv-prewarm.key'
    try:
        arch = bn.mac_gpu_arch(work, env, logs)
        host = bn.build_mac_host(REPO, work / 'tools/dmhost', env, logs, g)
    except (bn.BuildError, OSError, subprocess.CalledProcessError) as e:
        bn.say(f'[RED] prewarm pipelines: {e}; the app builds them on its first start'); return 0
    osversion = subprocess.run(['sysctl', '-n', 'kern.osversion'], capture_output=True, text=True).stdout
    key = prewarm_key(arch, gpus, chain, zero, text, host, lib, osversion)
    t0 = time.time()
    if keyf.is_file() and keyf.read_text().strip() == key and all(list(out.glob(f'{gpu}-prewarm-*.mtl4a')) for gpu in gpus):
        bn.say('prewarm pipelines: reused (inputs unchanged)')
    elif (out / 'key').is_file() and (out / 'key').read_text().strip() == key and list(out.glob(f'{arch}-prewarm-*.mtl4a')):   # this Mac's files are this key's: metal-tt again
        keyf.unlink(missing_ok=True)
        if bn.other_gpu_prewarm(REPO, out, arch, gpus, logs, lib if lib.is_dir() else lib.with_name(lib.name + '.img'), env, platform='tvos'): keyf.write_text(key + '\n')
    else:
        keyf.unlink(missing_ok=True); shutil.rmtree(out, ignore_errors=True)
        if not ((stage / 'key').is_file() and (stage / 'key').read_text().strip() == key): shutil.rmtree(stage, ignore_errors=True)   # an unfinished run of other inputs
        stage.mkdir(parents=True, exist_ok=True); (stage / 'key').write_text(key + '\n')
        bn.say(f'prewarm pipelines for {", ".join(gpus)}: {rows:,} rows, this Mac\'s host ({arch}) captures them, metal-tt builds them for the TV (minutes)')
        renv = dict(env, DM_PSO_PREBUILD='tool', DM_PSO_PREBUILD_PAIRS='0', DM_PSO_ARCHIVE=str(stage), DM_PSO_PREBUILD_OUT=str(out), DM_PSO_BUNDLE='off',
                    DM_PSO_MANIFEST=str(a.manifest), DM_MSL_DIR=str(a.msl), DM_NVN_SHMAP=str(a.shader_map))
        if zero: renv['DM_PSO_PREBUILD_DEPTH'] = 'zero'
        for k in ('DM_WINDOW', 'DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_SAVE', 'DM_PSO_USER', 'DM_PSO_PREBUILD_WARM'): renv.pop(k, None)   # the app's list alone, not a player's
        if bn.run([host], logs / 'pso_prewarm_tv.log', env=renv, fatal=False) or not list(out.glob(f'{arch}-prewarm-*.mtl4a')):
            shutil.rmtree(out, ignore_errors=True); link_into(out, a.bundle, gpus)
            bn.say(f'[RED] prewarm pipelines: the host\'s prebuild tool failed (see {logs / "pso_prewarm_tv.log"}); the app is packed without them and builds them on its first start'); return 0
        (out / 'key').write_text(key + '\n')
        shutil.rmtree(stage, ignore_errors=True)   # the work folder is kept only while a run is unfinished
        if bn.other_gpu_prewarm(REPO, out, arch, gpus, logs, lib if lib.is_dir() else lib.with_name(lib.name + '.img'), env, platform='tvos'):
            keyf.write_text(key + '\n')   # a period left out for a GPU: no key, so the next build tries again
    n, size = link_into(out, a.bundle, gpus)
    bn.say(f'prewarm pipelines in the app: {n} files, {bn.amount(size, "B")} ({time.time() - t0:.0f} s)' if n else '[RED] prewarm pipelines: none for the TV (see the lines above); its first start builds them')
    return 0


if __name__ == '__main__':
    sys.exit(main())
