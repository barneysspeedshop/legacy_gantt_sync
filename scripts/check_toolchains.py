#!/usr/bin/env python3
"""Fail release checks when the installed toolchains differ from reviewed pins."""
import json
from pathlib import Path
import re
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    targets = json.loads((root / 'toolchains.json').read_text())
    flutter = json.loads(subprocess.check_output(
        ['flutter', '--suppress-analytics', '--version', '--machine'], text=True))
    observed = {'flutter': flutter['frameworkVersion'],
                'flutter_dart': flutter['dartSdkVersion'].split()[0],
                'python': sys.version.split()[0]}
    commands = {'dart': ['dart', '--version'], 'node': ['node', '--version'],
                'rust': ['rustc', '--version'], 'go': ['go', 'version'],
                'protoc': ['protoc', '--version']}
    for name, command in commands.items():
        output = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)
        version = re.search(r'\b(?:v|go)?(\d+\.\d+(?:\.\d+)?(?:-[\w.-]+)?)(?:\b|$)', output)
        if not version:
            raise SystemExit(f'Cannot parse {name} version')
        observed[name] = version.group(1)
    mismatches = []
    for name, version in observed.items():
        print(f'{name}: {version} (required {targets[name]})')
        if version != targets[name]:
            mismatches.append(name)
    if mismatches:
        raise SystemExit('Toolchain mismatch: ' + ', '.join(mismatches))


if __name__ == '__main__':
    main()
