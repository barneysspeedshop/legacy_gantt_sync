#!/usr/bin/env python3
"""Run plugin dependency checks in a Linux namespace with no host home or credentials.

Requires bubblewrap and Node24. Only tracked plugin files and public system/Node
tools enter the sandbox. Network is available for npm's registry checks, then
disabled before dependency code runs. The host home, environment, Docker socket,
Git metadata, and operator files are absent.
"""
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    plugin = root / 'legacy_gantt_plugin'
    bwrap = shutil.which('bwrap')
    node = shutil.which('node')
    if not bwrap or not node:
        raise SystemExit('Install bubblewrap and Node24; no unsandboxed fallback is provided')
    binary = Path(node).resolve()
    prefix = binary.parent.parent
    npm = prefix / 'lib/node_modules/npm'
    if not npm.is_dir():
        raise SystemExit('Expected Node and npm in the same installation prefix')
    with tempfile.TemporaryDirectory(prefix='gantt-plugin-sandbox-') as directory:
        work = Path(directory)
        project = work / 'project'
        project.mkdir()
        names = subprocess.check_output(['git', '-C', str(plugin), 'ls-files', '-z'])
        for raw in names.split(b'\0'):
            if not raw:
                continue
            source = plugin / raw.decode()
            if source.is_symlink():
                raise SystemExit(f'Symlink requires review before sandbox inclusion: {raw.decode()}')
            if source.is_file():
                target = project / raw.decode()
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        home = work / 'home'
        home.mkdir()
        (home / '.npmrc').touch()
        (home / 'global.npmrc').touch()
        probe = work / 'hook-probe'
        probe.mkdir()
        shutil.copyfile(project / '.npmrc', probe / '.npmrc')
        (probe / 'package.json').write_text(json.dumps({
            'name': 'gantt-install-hook-probe', 'version': '1.0.0', 'private': True,
            'scripts': {'preinstall': 'touch install-hook-ran', 'postinstall': 'touch install-hook-ran'},
        }))
        command = [bwrap, '--unshare-all', '--new-session', '--die-with-parent',
                   '--cap-drop', 'ALL', '--clearenv', '--ro-bind', '/usr', '/usr',
                   '--symlink', 'usr/bin', '/bin', '--symlink', 'usr/lib', '/lib',
                   '--symlink', 'usr/lib64', '/lib64', '--dir', '/opt/node/bin',
                   '--ro-bind', str(binary), '/opt/node/bin/node',
                   '--ro-bind', str(npm), '/opt/node/lib/node_modules/npm',
                   '--symlink', '../lib/node_modules/npm/bin/npm-cli.js', '/opt/node/bin/npm',
                   '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp',
                   '--bind', str(work), '/work', '--dir', '/etc',
                   '--ro-bind', '/etc/ssl/certs', '/etc/ssl/certs',
                   '--ro-bind', '/etc/resolv.conf', '/etc/resolv.conf',
                   '--setenv', 'PATH', '/opt/node/bin:/usr/bin:/bin',
                   '--setenv', 'HOME', '/work/home', '--setenv', 'CI', 'true',
                   '--setenv', 'NPM_CONFIG_USERCONFIG', '/work/home/.npmrc',
                   '--setenv', 'NPM_CONFIG_GLOBALCONFIG', '/work/home/global.npmrc',
                   '--chdir', '/work/project']
        install = command + ['--share-net', '--', '/bin/sh', '-eu', '-c',
                             'cd /work/hook-probe; npm install --offline --no-audit; '
                             'test ! -e install-hook-ran; echo "Install hooks were blocked"; '
                             'cd /work/project; npm ci --ignore-scripts; npm audit signatures; '
                             'python3 scripts/test_audit_dependencies.py; python3 scripts/audit_dependencies.py']
        test = command + ['--', '/bin/sh', '-eu', '-c',
                          'test ! -e /home && test ! -e /var/run/docker.sock; npm test']
        for step in (install, test):
            subprocess.run(step, check=True, timeout=900, env={'PATH': os.defpath})


if __name__ == '__main__':
    main()
