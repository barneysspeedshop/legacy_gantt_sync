#!/usr/bin/env python3
"""Check resolved Dart, Rust, and Go dependencies against OSV (Python3.11+).

Only public package names and versions are sent. npm is checked separately by
the plugin's registry-signature and advisory gate. No dependency code is run.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib
import urllib.request

import yaml

from audit_supply_chain import repositories


def packages(root):
    found = set()
    for repo in repositories(root):
        names = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z']).split(b'\0')
        paths = [repo / raw.decode() for raw in names if raw]
        locks = [p.with_suffix('.lock') for p in paths if p.name == 'pubspec.yaml']
        for path in locks:
            if not path.exists():
                continue
            if path.is_symlink() or not path.resolve().is_relative_to(repo.resolve()):
                raise ValueError(f'lockfile is outside the repository: {path}')
            data = yaml.safe_load(path.read_text())
            for name, item in data.get('packages', {}).items():
                description = item.get('description', {})
                if item.get('source') == 'hosted' and description.get('url') == 'https://pub.dev':
                    found.add(('Pub', name, item['version']))
        for path in (p for p in paths if p.name == 'Cargo.lock'):
            if path.is_symlink():
                raise ValueError(f'symlinked lockfile: {path}')
            for item in tomllib.loads(path.read_text()).get('package', []):
                if item.get('source') in {'registry+https://github.com/rust-lang/crates.io-index',
                                          'registry+sparse+https://index.crates.io/'}:
                    found.add(('crates.io', item['name'], item['version']))
        for path in (p for p in paths if p.name == 'go.mod'):
            if path.is_symlink():
                raise ValueError(f'symlinked manifest: {path}')
            for name, version in re.findall(r'^\s*(?:require\s+)?([\w./~-]+)\s+(v[\w.+~-]+)',
                                             path.read_text(), re.MULTILINE):
                found.add(('Go', name, version))
    return sorted(found)


def main():
    root = Path(__file__).resolve().parent.parent
    versions = packages(root)
    if not versions:
        raise ValueError('no resolved dependencies found; scan is incomplete')
    findings = {}
    for start in range(0, len(versions), 100):
        batch = versions[start:start + 100]
        request = urllib.request.Request('https://api.osv.dev/v1/querybatch',
            data=json.dumps({'queries': [
                {'package': {'ecosystem': ecosystem, 'name': name}, 'version': version}
                for ecosystem, name, version in batch]}).encode(),
            headers={'Content-Type': 'application/json'}, method='POST')
        with urllib.request.urlopen(request, timeout=60) as response:
            results = json.load(response)['results']
        if len(results) != len(batch):
            raise ValueError('incomplete OSV response')
        for package, result in zip(batch, results):
            for advisory in result.get('vulns', []):
                findings.setdefault(advisory['id'], set()).add(package)
    failures = 0
    maintenance = 0
    for advisory, affected in sorted(findings.items()):
        with urllib.request.urlopen('https://api.osv.dev/v1/vulns/' + advisory, timeout=60) as response:
            details = json.load(response)
        if details.get('withdrawn'):
            continue
        informational = [item.get('database_specific', {}).get('informational')
                         for item in details.get('affected', [])]
        is_maintenance = bool(informational) and all(value == 'unmaintained' for value in informational)
        maintenance += int(is_maintenance)
        failures += int(not is_maintenance)
        for ecosystem, name, version in sorted(affected):
            label = 'Maintenance notice' if is_maintenance else 'Security advisory'
            print(f'{label}: {ecosystem} {name}@{version}: https://osv.dev/vulnerability/{advisory}')
    print(f'Checked {len(versions)} public Dart/Rust/Go package versions: '
          f'{failures} security advisories, {maintenance} maintenance notices')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
