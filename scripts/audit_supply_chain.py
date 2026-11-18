#!/usr/bin/env python3
"""Check owned workflows and npm lockfiles without installing or executing packages."""
import json
from pathlib import Path
import re
import subprocess
import sys

import yaml


DEPLOY_CONDITION = "github.event_name == 'push' && github.ref == 'refs/heads/main'"
DEPLOY_ACTIONS = {'actions/download-artifact', 'peaceiris/actions-gh-pages'}
ACTION = re.compile(r'^([\w.-]+/[\w./-]+)@[a-f0-9]{40}$')


def unsafe_npm_install(line):
    installs = re.findall(r'\bnpm\s+(?:ci|install)\b', line)
    if not installs:
        return False
    flags = re.findall(r'--(?:no-)?ignore-scripts(?:=[^\s;&)]+)?', line)
    return len(installs) != 1 or not flags or any(
        flag not in {'--ignore-scripts', '--ignore-scripts=true'} for flag in flags)


def audit_workflow(path):
    problems = []
    try:
        data = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
        if not isinstance(data, dict):
            raise ValueError('expected a workflow mapping')
        events = data.get('on', {})
        if isinstance(events, str):
            events = [events]
        if set(events) & {'pull_request_target', 'workflow_run', 'workflow_call'}:
            problems.append('privileged or reusable trigger needs a separate security review')
        if data.get('permissions') != {'contents': 'read'}:
            problems.append('workflow must default to contents: read')
        for expression in re.findall(r'\$\{\{(.*?)\}\}', json.dumps(data)):
            if re.search(r'\bsecrets\b', expression.replace('secrets.GITHUB_TOKEN', '')):
                problems.append('package-publishing or cloud secrets must not enter workflows')
        if 'secrets.' in json.dumps(data.get('env', {})):
            problems.append('secrets must not be exposed through workflow-wide environment')
        for name, job in data.get('jobs', {}).items():
            if job.get('uses') or job.get('secrets'):
                problems.append(f'{name}: reusable jobs and inherited secrets require separate review')
            if 'self-hosted' in str(job.get('runs-on', '')):
                problems.append(f'{name}: use an ephemeral GitHub-hosted runner')
            permissions = job.get('permissions', data.get('permissions', {}))
            if not isinstance(permissions, dict):
                problems.append(f'{name}: permissions must be explicit')
                continue
            privileged = 'write' in permissions.values()
            if privileged:
                push = events.get('push', {}) if isinstance(events, dict) else {}
                if (set(events) != {'push'} or push.get('branches') != ['main']
                        or job.get('if') != DEPLOY_CONDITION or job.get('needs') != 'build'
                        or permissions != {'contents': 'write'}):
                    problems.append(f'{name}: writes are restricted to isolated main-branch deployment')
            elif 'secrets.' in json.dumps(job) or 'github.token' in json.dumps(job):
                problems.append(f'{name}: build/test jobs must not receive secrets or explicit tokens')
            for step in job.get('steps', []):
                uses = step.get('uses', '')
                match = ACTION.fullmatch(uses) if uses else None
                if uses and not match:
                    problems.append(f'{name}: action is not pinned to a full commit: {uses}')
                action = match.group(1) if match else ''
                if action == 'actions/checkout' and step.get('with', {}).get('persist-credentials') != 'false':
                    problems.append(f'{name}: checkout must not persist credentials')
                if privileged and (step.get('run') or action not in DEPLOY_ACTIONS):
                    problems.append(f'{name}: deployment must only download and publish static artifacts')
                if re.search(r'\$\{\{\s*github\.event\.', step.get('run', '')):
                    problems.append(f'{name}: do not interpolate untrusted event data into shell code')
                if re.search(r'\bnpm\s+(?:ci|install)\b', step.get('run', '')):
                    for line in step['run'].splitlines():
                        if unsafe_npm_install(line):
                            problems.append(f'{name}: npm installation must disable lifecycle scripts')
    except (OSError, ValueError, TypeError, yaml.YAMLError) as error:
        problems.append(f'invalid workflow: {error}')
    return [f'{path}: {problem}' for problem in problems]


def repositories(root):
    yield root
    entries = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--stage', '-z'])
    for entry in entries.split(b'\0'):
        if entry.startswith(b'160000 '):
            child = root / entry.split(b'\t', 1)[1].decode()
            if not (child / '.git').exists():
                raise ValueError(f'uninitialized submodule: {child.name}')
            yield from repositories(child)


def audit_npm(repo, manifest):
    problems = []
    config = manifest.parent / '.npmrc'
    if not config.is_file() or 'ignore-scripts=true' not in config.read_text().splitlines():
        problems.append(f'{manifest}: project must disable npm lifecycle scripts')
    lock = manifest.with_name('package-lock.json')
    if not lock.is_file():
        return problems + [f'{manifest}: missing npm lockfile']
    data = json.loads(lock.read_text())
    for name, package in data.get('packages', {}).items():
        if not name:
            continue
        if (not package.get('resolved', '').startswith('https://registry.npmjs.org/')
                or not package.get('integrity', '').startswith('sha512-') or package.get('link')):
            problems.append(f'{lock}: {name} must use a registry artifact with SHA-512 integrity')
    return problems


def audit_dockerfile(path):
    problems = []
    for line in path.read_text().splitlines():
        match = re.match(r'^FROM\s+(\S+)', line, re.I)
        if match and not re.fullmatch(r'[^\s]+@sha256:[a-f0-9]{64}', match.group(1)):
            problems.append(f'{path}: base image must use an immutable SHA-256 manifest')
    return problems


def main():
    root = Path(__file__).resolve().parent.parent
    problems = []
    repos = list(repositories(root))
    count = 0
    for repo in repos:
        names = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z']).split(b'\0')
        for raw in names:
            name = raw.decode()
            path = repo / name
            if name.startswith('.github/workflows/') and path.suffix in ('.yml', '.yaml'):
                problems.extend(audit_workflow(path))
                count += 1
            if name == 'package.json':
                problems.extend(audit_npm(repo, path))
            if path.name == 'Dockerfile':
                problems.extend(audit_dockerfile(path))
    script = root / 'scripts/check_release.sh'
    for line in script.read_text().splitlines():
        if unsafe_npm_install(line):
            problems.append(f'{script}: npm installation must explicitly disable lifecycle scripts')
    for problem in problems:
        print(problem)
    print(f'Checked {count} workflows across {len(repos)} repositories: {len(problems)} problems')
    return bool(problems)


if __name__ == '__main__':
    sys.exit(main())
