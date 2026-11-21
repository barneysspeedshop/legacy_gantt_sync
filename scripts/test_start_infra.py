#!/usr/bin/env python3
"""Exercise start_infra.sh without contacting a real Docker daemon."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parent.parent
START_INFRA = ROOT / "start_infra.sh"
POSTGRES_IMAGE = (
    "postgres:18.7@sha256:"
    "eb63372c1e05c755f55fa30cbd07aecc443676fc6c0fa90b9002d01537841e1a"
)
REDIS_IMAGE = (
    "redis:8.10.3@sha256:"
    "1f88291b4c57bdf249f02eb085a8669889b2d2954e91d4de5118a5da6b78dd53"
)


MOCK_SUDO = """\
#!/usr/bin/env python3
import os
import shutil
import sys

target = shutil.which(sys.argv[1]) or sys.argv[1]
os.execv(target, [target, *sys.argv[2:]])
"""


MOCK_DOCKER = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["MOCK_DOCKER_ROOT"])
state_path = root / "state.json"
log_path = root / "calls.jsonl"
state = json.loads(state_path.read_text())
args = sys.argv[1:]
with log_path.open("a") as stream:
    stream.write(json.dumps(args) + "\n")

def save():
    state_path.write_text(json.dumps(state, sort_keys=True))

if args[:3] == ["container", "ls", "-aq"]:
    expression = args[args.index("--filter") + 1]
    name = expression.removeprefix("name=^/").removesuffix("$")
    if name in state:
        print(state[name]["id"])
    raise SystemExit(0)

if args[:2] == ["container", "inspect"]:
    name = args[-1]
    if name not in state:
        print(f"Error: No such object: {name}", file=sys.stderr)
        raise SystemExit(1)
    template = args[args.index("--format") + 1]
    print(template.replace("{{.Config.Image}}", state[name]["image"])
                  .replace("{{.State.Status}}", state[name]["status"]))
    raise SystemExit(0)

if args[:1] == ["start"]:
    name = args[1]
    state[name]["status"] = "running"
    save()
    print(name)
    raise SystemExit(0)

if args[:1] == ["run"]:
    name = args[args.index("--name") + 1]
    image = args[-1]
    state[name] = {"id": f"{name}-new", "image": image, "status": "running"}
    save()
    print(state[name]["id"])
    raise SystemExit(0)

print(f"unsupported mock docker command: {args}", file=sys.stderr)
raise SystemExit(2)
'''


class StartInfraTest(unittest.TestCase):
    def run_launcher(self, containers):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "state.json").write_text(json.dumps(containers))
            (root / "calls.jsonl").touch()
            sudo = root / "sudo"
            docker = root / "docker"
            sudo.write_text(textwrap.dedent(MOCK_SUDO))
            docker.write_text(textwrap.dedent(MOCK_DOCKER))
            sudo.chmod(0o755)
            docker.chmod(0o755)
            environment = {
                **os.environ,
                "MOCK_DOCKER_ROOT": str(root),
                "DB_PASS": "local password with spaces",
            }
            environment["PATH"] = f"{root}:{environment['PATH']}"
            result = subprocess.run(
                [str(START_INFRA)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            state = json.loads((root / "state.json").read_text())
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            return result, state, calls

    @staticmethod
    def mutations(calls):
        return [call for call in calls if call and call[0] in {"run", "start", "rm"}]

    def test_fresh_containers_use_pinned_images_and_loopback_ports(self):
        result, state, calls = self.run_launcher({})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["redis"]["image"], REDIS_IMAGE)
        self.assertEqual(state["legacy_db"]["image"], POSTGRES_IMAGE)
        mutations = self.mutations(calls)
        self.assertEqual([call[0] for call in mutations], ["run", "run"])
        redis_run, postgres_run = mutations
        self.assertIn("127.0.0.1:6379:6379", redis_run)
        self.assertIn("redis_data:/data", redis_run)
        self.assertIn("127.0.0.1:5432:5432", postgres_run)
        self.assertIn("pgdata:/var/lib/postgresql", postgres_run)
        self.assertIn("POSTGRES_PASSWORD=local password with spaces", postgres_run)

    def test_old_postgres_is_refused_before_any_mutation(self):
        result, _, calls = self.run_launcher({
            "legacy_db": {"id": "old-pg", "image": "postgres:15", "status": "exited"},
        })

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docs/postgresql-18-migration.md", result.stderr)
        self.assertEqual(self.mutations(calls), [])

    def test_old_redis_is_refused_before_any_mutation(self):
        result, _, calls = self.run_launcher({
            "redis": {"id": "old-redis", "image": "redis:7", "status": "exited"},
        })

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docs/postgresql-18-migration.md", result.stderr)
        self.assertEqual(self.mutations(calls), [])

    def test_matching_stopped_containers_start_in_place(self):
        result, state, calls = self.run_launcher({
            "redis": {"id": "redis-old", "image": REDIS_IMAGE, "status": "exited"},
            "legacy_db": {"id": "pg-old", "image": POSTGRES_IMAGE, "status": "created"},
        })

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[:2] for call in self.mutations(calls)],
                         [["start", "redis"], ["start", "legacy_db"]])
        self.assertNotIn("run", [call[0] for call in calls])
        self.assertEqual(state["redis"]["status"], "running")
        self.assertEqual(state["legacy_db"]["status"], "running")


if __name__ == "__main__":
    unittest.main()
