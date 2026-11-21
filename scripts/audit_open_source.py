#!/usr/bin/env python3
"""Scan tracked publishable files and optionally every local Git ref without printing secrets.

Requires Gitleaks v8 on PATH (or --gitleaks /path/to/gitleaks).
Only index-tracked files are scanned; add new source files to the index before
running this check. Working-tree content for tracked files is scanned.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args])


def repositories(root):
    yield root
    for entry in git(root, 'ls-files', '--stage', '-z').split(b'\0'):
        if entry.startswith(b'160000 '):
            path = root / entry.split(b'\t', 1)[1].decode()
            if not (path / '.git').exists():
                raise RuntimeError(f'Submodule is not initialized: {path.name}')
            yield from repositories(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true', help='Scan all local Git refs as well')
    parser.add_argument('--gitleaks', default='gitleaks')
    args = parser.parse_args()
    binary = shutil.which(args.gitleaks)
    if not binary:
        parser.error('Install Gitleaks v8 or supply --gitleaks')
    root = Path(__file__).resolve().parent.parent
    findings = 0
    for repo in repositories(root):
        label = str(repo.relative_to(root))
        with tempfile.TemporaryDirectory(prefix='gantt-audit-') as temp:
            temp = Path(temp)
            snapshot = temp / 'publishable'
            snapshot.mkdir()
            names = git(repo, 'ls-files', '--cached', '-z')
            for raw in set(names.split(b'\0')):
                if not raw:
                    continue
                name = raw.decode()
                source = repo / name
                if source.is_file() and not source.is_symlink():
                    target = snapshot / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
            modes = [('worktree', ['dir', str(snapshot)])]
            if args.history:
                modes.append(('history', ['git', str(repo), '--log-opts=--all']))
            for mode, command in modes:
                report = temp / f'{mode}.json'
                result = subprocess.run(
                    [binary, *command, '--redact=100', '--no-banner', '--exit-code=1',
                     '--report-format=json', f'--report-path={report}'],
                    capture_output=True,
                )
                if result.returncode not in (0, 1) or not report.exists():
                    raise RuntimeError(f'{label}: {mode} scanner failed (exit {result.returncode}); output withheld to protect credentials')
                rows = json.loads(report.read_text()) or []
                findings += len(rows)
                print(f'{label} {mode}: {len(rows)} findings')
                for row in rows:
                    file = row['File']
                    if mode == 'worktree':
                        file = str(Path(file).relative_to(snapshot)) if Path(file).is_absolute() else file
                    print(f"  {file}:{row['StartLine']} rule={row['RuleID']} commit={row.get('Commit', '')[:12]}")
    return 1 if findings else 0


if __name__ == '__main__':
    raise SystemExit(main())
