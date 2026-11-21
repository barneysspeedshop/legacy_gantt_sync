#!/usr/bin/env python3
"""Clone tracked publishable source, including dirty submodules, into a sandbox.

Temporary candidate commits are created only in the output directory. The source
checkout, its index, branches, and history are never changed. Only files tracked
in each source index are copied; add new source files before running this check.
Working-tree content for tracked files remains included.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

from audit_open_source import git, repositories


def run(repo, *args):
    return subprocess.check_output([
        'git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
        '-c', 'user.name=Release Check', '-c', 'user.email=release-check@example.invalid',
        '-C', str(repo), *args,
    ])


def children(repo):
    for entry in git(repo, 'ls-files', '--stage', '-z').split(b'\0'):
        if entry.startswith(b'160000 '):
            yield entry.split(b'\t', 1)[1].decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='New or empty output directory')
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix='gantt-release-checkout-'))
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Output directory must be empty')
    source = Path(__file__).resolve().parent.parent
    if output.is_relative_to(source):
        parser.error('Output must be outside the source checkout')
    output.mkdir(parents=True, exist_ok=True)
    repos = list(repositories(source))
    exports = {repo: output / 'candidates' / str(index) for index, repo in enumerate(repos)}
    commits = {}
    for repo in reversed(repos):
        candidate = exports[repo]
        candidate.mkdir(parents=True)
        names = git(repo, 'ls-files', '--cached', '-z')
        for raw in set(names.split(b'\0')):
            if not raw:
                continue
            original = repo / raw.decode()
            if original.is_file() or original.is_symlink():
                destination = candidate / raw.decode()
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, destination, follow_symlinks=False)
        run(candidate, 'init', '--quiet')
        run(candidate, 'add', '--force', '--all')
        for path in children(repo):
            run(candidate, 'update-index', '--add', '--cacheinfo',
                f'160000,{commits[repo / path]},{path}')
        run(candidate, 'commit', '--quiet', '--allow-empty', '-m', 'Local release candidate snapshot')
        commits[repo] = run(candidate, 'rev-parse', 'HEAD').decode().strip()

    checkout = output / 'checkout'
    subprocess.run(['git', 'clone', '--quiet', '--no-local', str(exports[source]), str(checkout)], check=True)
    for repo in repos:
        clone = checkout / repo.relative_to(source)
        if not list(children(repo)):
            continue
        modules = run(clone, 'config', '--file', '.gitmodules', '--get-regexp', r'^submodule\..*\.path$')
        for line in modules.decode().splitlines():
            key, path = line.split(None, 1)
            run(clone, 'config', key.removesuffix('.path') + '.url', str(exports[repo / path]))
        run(clone, '-c', 'protocol.file.allow=always', 'submodule', 'update', '--init')
    assert not run(checkout, 'status', '--porcelain'), 'Candidate checkout is dirty'
    statuses = run(checkout, 'submodule', 'status', '--recursive').decode().splitlines()
    assert all(line.startswith(' ') for line in statuses), 'Submodule commits do not match'
    print(f'Clean candidate clone: {checkout}')
    print(f'Root and {len(repos) - 1} submodules committed only in {output / "candidates"}')


if __name__ == '__main__':
    main()
