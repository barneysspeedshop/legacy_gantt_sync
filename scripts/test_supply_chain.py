#!/usr/bin/env python3
"""Exercise the trust boundaries enforced by the workflow policy."""
from pathlib import Path
import tempfile
import unittest

from audit_supply_chain import audit_dockerfile, audit_workflow


WORKFLOW = '''name: Test
on:
  pull_request:
permissions:
  contents: read
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: false
      - run: npm ci --ignore-scripts
'''


class WorkflowPolicyTest(unittest.TestCase):
    def check(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.yml'
            path.write_text(text)
            return audit_workflow(path)

    def test_read_only_pinned_pr_build_passes(self):
        self.assertEqual(self.check(WORKFLOW), [])

    def test_movable_action_is_rejected(self):
        result = self.check(WORKFLOW.replace('3d3c42e5aac5ba805825da76410c181273ba90b1', 'main'))
        self.assertTrue(any('not pinned' in problem for problem in result))

    def test_persisted_git_credentials_are_rejected(self):
        result = self.check(WORKFLOW.replace('persist-credentials: false', 'persist-credentials: true'))
        self.assertTrue(any('must not persist' in problem for problem in result))

    def test_privileged_pr_trigger_is_rejected(self):
        result = self.check(WORKFLOW.replace('pull_request:', 'pull_request_target:'))
        self.assertTrue(any('trigger' in problem for problem in result))

    def test_build_with_write_token_is_rejected(self):
        result = self.check(WORKFLOW.replace('runs-on: ubuntu-latest',
                                            'permissions: {contents: write}\n    runs-on: ubuntu-latest'))
        self.assertTrue(any('deployment' in problem for problem in result))

    def test_install_hooks_are_rejected(self):
        result = self.check(WORKFLOW.replace('npm ci --ignore-scripts', 'npm ci'))
        self.assertTrue(any('lifecycle' in problem for problem in result))

    def test_explicit_hook_override_is_rejected(self):
        result = self.check(WORKFLOW.replace('npm ci --ignore-scripts', 'npm ci --ignore-scripts=false'))
        self.assertTrue(any('lifecycle' in problem for problem in result))

    def test_secret_collection_is_rejected(self):
        result = self.check(WORKFLOW.replace('npm ci --ignore-scripts', 'echo "${{ toJSON(secrets) }}"'))
        self.assertTrue(any('secrets must not enter' in problem for problem in result))

    def test_reusable_job_secret_inheritance_is_rejected(self):
        result = self.check(WORKFLOW.replace('runs-on: ubuntu-latest', 'secrets: inherit\n    runs-on: ubuntu-latest'))
        self.assertTrue(any('inherited secrets' in problem for problem in result))


class ImagePolicyTest(unittest.TestCase):
    def test_tag_without_digest_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Dockerfile'
            path.write_text('FROM rust:latest AS build\n')
            self.assertEqual(audit_dockerfile(path),
                             [f'{path}: base image must use an immutable SHA-256 manifest'])

    def test_pinned_image_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Dockerfile'
            path.write_text('FROM rust:1.93.0@sha256:' + 'a' * 64 + ' AS build\n')
            self.assertEqual(audit_dockerfile(path), [])


if __name__ == '__main__':
    unittest.main()
