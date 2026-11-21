#!/usr/bin/env python3
"""Verify release helpers copy only files tracked by the source index."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parent.parent
AUDIT_SCRIPT = ROOT / "scripts" / "audit_open_source.py"
CHECKOUT_SCRIPT = ROOT / "scripts" / "create_release_checkout.py"


FAKE_GITLEAKS = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

report = next(argument.split("=", 1)[1] for argument in sys.argv if argument.startswith("--report-path="))
snapshot = Path(sys.argv[2])
scanned = sorted(str(path.relative_to(snapshot)) for path in snapshot.rglob("*") if path.is_file())
Path(os.environ["GITLEAKS_LOG"]).write_text(json.dumps({
    "files": scanned,
    "tracked_content": (snapshot / "tracked.txt").read_text(),
}))
Path(report).write_text("[]")
'''


class ReleaseFileScopeTest(unittest.TestCase):
    def make_source(self, temporary):
        source = temporary / "source"
        source.mkdir()
        scripts = source / "scripts"
        scripts.mkdir()
        shutil.copy2(AUDIT_SCRIPT, scripts / AUDIT_SCRIPT.name)
        shutil.copy2(CHECKOUT_SCRIPT, scripts / CHECKOUT_SCRIPT.name)
        self.git(source, "init", "--quiet")
        self.write(source / ".gitignore", "tracked-ignored.txt\n")
        self.write(source / "tracked.txt", "committed content\n")
        self.write(source / "tracked-ignored.txt", "tracked ignored content\n")
        self.git(source, "add", ".gitignore", "tracked.txt")
        self.git(source, "add", "--force", "tracked-ignored.txt")
        self.git(source, "-c", "user.name=Fixture", "-c",
                 "user.email=fixture@example.invalid", "commit", "--quiet",
                 "-m", "fixture")
        self.write(source / "tracked.txt", "modified tracked content\n")
        self.write(source / "operator.txt", "operator secret must stay out\n")
        return source

    @staticmethod
    def write(path, content):
        path.write_text(content)

    @staticmethod
    def git(source, *arguments):
        return subprocess.run(["git", "-C", str(source), *arguments],
                              check=True, capture_output=True, text=True,
                              env=ReleaseFileScopeTest.environment(source.parent / "home"))

    @staticmethod
    def environment(home):
        return {
            **os.environ,
            "HOME": str(home),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
        }

    def test_audit_cli_scans_dirty_tracked_files_only(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            source = self.make_source(temporary)
            fake = temporary / "gitleaks"
            fake.write_text(textwrap.dedent(FAKE_GITLEAKS))
            fake.chmod(0o755)
            scan_log = temporary / "scan.json"
            environment = self.environment(temporary / "home")
            environment["GITLEAKS_LOG"] = str(scan_log)

            result = subprocess.run(
                [sys.executable, str(source / "scripts/audit_open_source.py"),
                 "--gitleaks", str(fake)],
                cwd=source,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            observed = json.loads(scan_log.read_text())
            scanned = observed["files"]
            self.assertIn("tracked.txt", scanned)
            self.assertIn("tracked-ignored.txt", scanned)
            self.assertEqual(observed["tracked_content"], "modified tracked content\n")
            self.assertEqual((source / "tracked.txt").read_text(),
                             "modified tracked content\n")
            self.assertNotIn("operator.txt", scanned)
            self.assertNotIn("operator secret", result.stdout)

    def test_release_checkout_cli_exports_dirty_tracked_files_only(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            source = self.make_source(temporary)
            output = temporary / "release"
            environment = self.environment(temporary / "home")

            result = subprocess.run(
                [sys.executable, str(source / "scripts/create_release_checkout.py"),
                 "--output", str(output)],
                cwd=source,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            exported = output / "candidates/0"
            checkout = output / "checkout"
            for location in (exported, checkout):
                self.assertEqual((location / "tracked.txt").read_text(),
                                 "modified tracked content\n")
                self.assertEqual((location / "tracked-ignored.txt").read_text(),
                                 "tracked ignored content\n")
                self.assertFalse((location / "operator.txt").exists())
            self.assertFalse(any(path.name == "operator.txt" for path in output.rglob("*")))


if __name__ == "__main__":
    unittest.main()
