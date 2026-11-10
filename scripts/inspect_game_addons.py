#!/usr/bin/env python3
"""Read package metadata before TVPort attaches an update or DLC. Never extracts game data."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import sys

SUFFIXES = {'.nsp', '.xci', '.nsz', '.xcz'}


def source_files(paths):
    result = []
    for value in paths:
        path = Path(value).expanduser().resolve()
        if not path.exists():
            raise ValueError(f'{path.name} is unavailable. Reconnect its drive and try again.')
        candidates = sorted(path.iterdir()) if path.is_dir() else [path]
        files = [p for p in candidates if p.is_file() and p.suffix.lower() in SUFFIXES and not p.name.startswith('._')]
        if not files:
            raise ValueError(f'{path.name} has no NSP, XCI, NSZ or XCZ files.')
        result.extend(files)
    return list(dict.fromkeys(result))


def validate_records(base_records, records, expected=''):
    applications = {title for content in base_records for kind, title, _ in content if kind == 'Application'}
    if len(applications) != 1:
        raise ValueError('Could not identify one base game from its package metadata. Choose a folder containing one base game and check your prod.keys.')
    application = applications.pop()
    if expected and application != int(expected, 16):
        raise ValueError('The base game files do not match this library game.')
    addons = []
    for path, content in records:
        if not content:
            raise ValueError(f'Could not read metadata from {path.name}. Check your prod.keys and the file.')
        for kind, title, version in content:
            if kind not in ('Patch', 'AddOnContent'):
                raise ValueError(f'{path.name} contains a base game or unsupported content. Drop only updates or DLC onto an existing game.')
            parent = title & ~0xFFF if kind == 'Patch' else (title & ~0xFFF) - 0x1000
            if parent != application:
                raise ValueError(f'{path.name} belongs to a different game or region. Nothing was added.')
            addons.append({'path': str(path), 'kind': 'Update' if kind == 'Patch' else 'DLC',
                           'title_id': f'{title:016X}', 'version': version})
    return {'title_id': f'{application:016X}', 'addons': addons}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--keys', required=True, type=Path)
    parser.add_argument('--expected', default='')
    parser.add_argument('--source', action='append', required=True)
    args = parser.parse_args()
    import build_ipa_from_nsp as nsp
    try:
        repo = Path(__file__).resolve().parents[1]
        env = dict(os.environ)
        env['PATH'] = os.pathsep.join(nsp.TOOL_PATHS + [env.get('PATH', '')])
        bases, extras = source_files([args.folder]), source_files(args.source)
        # Extractor progress belongs on stderr; stdout is one JSON response.
        # One nx_extract run reads every package's content metas: {path: [(type, title ID, version)]}, or {path: why} for one it cannot read
        # (upstream replaced package_title_reader with package_reader; the old name raised AttributeError and every import failed)
        with contextlib.redirect_stdout(sys.stderr), nsp.package_reader(repo, args.keys, env) as reader:
            found = reader.contents(list(dict.fromkeys(bases + extras)))
        for path in extras:
            if isinstance(found.get(path), str):
                raise ValueError(f'Could not read metadata from {path.name}: {found[path]}')
        base_records = [found.get(path) if isinstance(found.get(path), list) else [] for path in bases]
        records = [(path, found.get(path) if isinstance(found.get(path), list) else []) for path in extras]
        result = validate_records(base_records, records, args.expected)
        print(json.dumps(result))
        return 0
    except (ValueError, OSError, nsp.BuildError) as error:
        print(json.dumps({'error': str(error)}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
