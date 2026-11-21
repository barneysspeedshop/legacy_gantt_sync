#!/usr/bin/env python3
"""Read tracked manifests and stable release feeds without executing package code."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import tomllib
import urllib.request

import yaml

from audit_supply_chain import repositories


def read_json(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'gantt-version-audit'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def pub_dependencies(root):
    entries = []
    for repo in repositories(root):
        names = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z'])
        for raw in names.split(b'\0'):
            if not raw or Path(raw.decode()).name != 'pubspec.yaml':
                continue
            path = repo / raw.decode()
            manifest = yaml.safe_load(path.read_text())
            lock = path.with_suffix('.lock')
            resolved = yaml.safe_load(lock.read_text())['packages'] if lock.exists() else {}
            for section in ('dependencies', 'dev_dependencies'):
                for name, constraint in (manifest.get(section) or {}).items():
                    if isinstance(constraint, dict):
                        continue
                    package = resolved.get(name, {})
                    entries.append({
                        'scope': str(path.parent.relative_to(root)),
                        'package': name,
                        'constraint': constraint,
                        'resolved': package.get('version'),
                        'source': package.get('source'),
                        'dev': section == 'dev_dependencies',
                    })
    names = sorted({entry['package'] for entry in entries})
    with ThreadPoolExecutor(max_workers=8) as pool:
        versions = dict(zip(names, pool.map(
            lambda name: read_json(f'https://pub.dev/api/packages/{name}')['latest']['version'],
            names)))
    return [dict(entry, latest=versions[entry['package']]) for entry in entries]


def npm_dependencies(root):
    directory = root / 'legacy_gantt_plugin'
    manifest = json.loads((directory / 'package.json').read_text())
    lock = json.loads((directory / 'package-lock.json').read_text())
    entries = []
    for section in ('dependencies', 'devDependencies'):
        for name, constraint in manifest[section].items():
            entries.append({
                'package': name,
                'constraint': constraint,
                'resolved': lock['packages'][f'node_modules/{name}']['version'],
                'latest': read_json(f'https://registry.npmjs.org/{name}/latest')['version'],
            })
    return entries


def stable_toolchains():
    flutter = read_json('https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json')
    node = read_json('https://nodejs.org/dist/index.json')
    with urllib.request.urlopen('https://static.rust-lang.org/dist/channel-rust-stable.toml',
                                timeout=30) as response:
        rust = tomllib.loads(response.read().decode())
    return {
        'flutter': next(release for release in flutter['releases']
                        if release['hash'] == flutter['current_release']['stable']
                        and release.get('dart_sdk_arch', 'x64') == 'x64'),
        'dart': read_json('https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION'),
        'go': read_json('https://go.dev/dl/?mode=json')[0]['version'],
        'node': next(release['version'] for release in node
                     if release.get('lts') and '-' not in release['version']),
        'rust': rust['pkg']['rust']['version'].split()[0],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    report = {'checked_at': datetime.now(timezone.utc).isoformat(),
              'toolchains': stable_toolchains(), 'pub': pub_dependencies(root),
              'npm': npm_dependencies(root)}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    for ecosystem in ('pub', 'npm'):
        outdated = [entry for entry in report[ecosystem]
                    if entry['resolved'] != entry['latest'] and entry.get('source') != 'path']
        print(f'{ecosystem}: {len(outdated)} declarations resolve below latest stable')
        for entry in outdated:
            print(f"  {entry.get('scope', 'plugin')}: {entry['package']} "
                  f"{entry['resolved']} -> {entry['latest']}")
    print(f'Full inventory: {args.output}')


if __name__ == '__main__':
    main()
