#!/usr/bin/env python3
"""Apply the ecosystem's GitHub policy, or print its current state by default.

Uses the already authenticated gh CLI. Reads settings, never secret values.
Administrator override stays available to the sole maintainer; ordinary changes
require reviewed, up-to-date CI. Run after workflow changes have merged.
"""
import argparse
import json
import subprocess


CHECKS = {
    'legacy_gantt_sync': ['security', 'verify', 'image'],
    'legacy_context_menu': ['verify'],
    'legacy_gantt_chart': ['build'],
    'legacy_gantt_plugin': ['verify'],
    'legacy_gantt_protocol': ['build'],
    'legacy_pert_chart': ['build'],
    'legacy_timeline_scrubber': ['test'],
    'legacy_tree_grid': ['test'],
}
PATTERNS = ['subosito/flutter-action@*', 'dart-lang/setup-dart@*',
            'dtolnay/rust-toolchain@*', 'peaceiris/actions-gh-pages@*']


def api(path, method='GET', data=None):
    command = ['gh', 'api', path, '--method', method]
    if data is not None:
        command += ['--input', '-']
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{method} {path}: {result.stderr.strip()}')
    return json.loads(result.stdout) if result.stdout.strip() else None


def protection(checks, linear):
    return {
        'required_status_checks': {'strict': True, 'checks': [
            {'context': name, 'app_id': 15368} for name in checks]},
        'enforce_admins': False,
        'required_pull_request_reviews': {
            'dismiss_stale_reviews': True, 'require_code_owner_reviews': True,
            'required_approving_review_count': 1},
        'restrictions': None,
        'required_linear_history': linear,
        'allow_force_pushes': False, 'allow_deletions': False,
        'required_conversation_resolution': True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--include-site', action='store_true', help='Disable unused Actions on the separate site')
    args = parser.parse_args()
    failures = []
    for name, checks in CHECKS.items():
        base = f'repos/barneysspeedshop/{name}'
        try:
            if args.apply:
                api(base + '/vulnerability-alerts', 'PUT')
                api(base, 'PATCH', {'delete_branch_on_merge': True, 'security_and_analysis': {
                    'secret_scanning': {'status': 'enabled'},
                    'secret_scanning_push_protection': {'status': 'enabled'}}})
                api(base + '/automated-security-fixes', 'PUT')
                api(base + '/actions/permissions/workflow', 'PUT', {
                    'default_workflow_permissions': 'read', 'can_approve_pull_request_reviews': False})
                api(base + '/actions/permissions/fork-pr-contributor-approval', 'PUT', {
                    'approval_policy': 'all_external_contributors'})
                api(base + '/actions/permissions', 'PUT', {'enabled': True, 'allowed_actions': 'selected'})
                api(base + '/actions/permissions/selected-actions', 'PUT', {
                    'github_owned_allowed': True, 'verified_allowed': False, 'patterns_allowed': PATTERNS})
                api(base + '/branches/main/protection', 'PUT', protection(checks, name == 'legacy_gantt_sync'))
            repo = api(base)
            tokens = api(base + '/actions/permissions/workflow')
            forks = api(base + '/actions/permissions/fork-pr-contributor-approval')
            branch = api(base + '/branches/main/protection')
            print(json.dumps({'repo': name, 'security': repo.get('security_and_analysis'),
                              'tokens': tokens, 'outside_approval': forks,
                              'protected_checks': branch['required_status_checks']['contexts'],
                              'reviews': branch['required_pull_request_reviews']['required_approving_review_count'],
                              'code_owners': branch['required_pull_request_reviews']['require_code_owner_reviews'],
                              'force_push': branch['allow_force_pushes']['enabled']}))
        except RuntimeError as error:
            failures.append(str(error))
    if args.include_site:
        base = 'repos/barneysspeedshop/legacy_gantt_sync_site'
        try:
            if args.apply:
                api(base + '/actions/permissions', 'PUT', {'enabled': False})
            print(json.dumps({'repo': 'legacy_gantt_sync_site', 'actions': api(base + '/actions/permissions')}))
        except RuntimeError as error:
            failures.append(str(error))
    for error in failures:
        print(error)
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
