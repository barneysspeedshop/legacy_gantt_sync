# Coordinated open-source release

## Candidate versions and requirements

| Package | Candidate | Requirement |
| --- | --- | --- |
| `legacy_gantt_protocol` | 3.0.1 | Dart 3.8 or newer |
| `legacy_timeline_scrubber` | 3.0.0 | Dart 3.10 / Flutter 3.38; nullable date fields and line-count mode |
| `legacy_gantt_chart` | 9.0.0 | Dart 3.10 / Flutter 3.38 or newer; protocol ^3.0.1 |
| `legacy_pert_chart` | 0.2.0 | Same Flutter baseline; chart ^9.0.0 and protocol ^3.0.1 |

The server and Config App retain their own application versions and use the checked-out protocol package. The plugin remains a prototype; its JSON sync client is not compatible with the production binary transport.

## Migration

Protocol 3.0.1 corrects equal-clock tombstone handling found during the final network tests after 3.0.0 was published. Publish 3.0.1 before chart 9.0.0 or PERT 0.2.0; their minimum protocol requirement excludes 3.0.0.

Upgrade production clients and server together: there is no JSON-text fallback on the production WebSocket endpoint. Use `ProtocolMessage` binary frames and `ProtobufMapper` for logical operation maps. The Go mock server still uses JSON and is not a production compatibility target.

The timeline scrubber now supports date-time and line-count modes, so its public task/widget date fields and date callbacks are nullable. Date-only consumers should select date-time mode and narrow nullable fields before use. The new release also fixes pointer-down drag initiation and padding preservation on zoom reset.

The protocol package now exports generated Protobuf models. Construct them with generated setters or factory fields. Task dates are UTC ISO-8601 strings, model clocks are serialized HLC strings, dependency lag uses `Int64`, and arbitrary metadata is encoded in `metadataJson`. Use `parsedLastUpdated` when an `Hlc` object is needed. Chart domain models still expose `DateTime` and `Hlc` and convert at the protocol boundary. Batch task records represent upserts, so decoded insert/update records use `UPDATE_TASK`; deletion markers and per-record clocks are preserved.

All first-party components use MIT. Keep authentication, tenant isolation, revocation, and third-party notices. The retired licensing key remains in historical commits; see [SECURITY.md](../../SECURITY.md) and [licensing migration](LICENSING.md).

**Rust scheduling is experimental and unsupported.** `OPTIMIZE_SCHEDULE` now returns an explicit error without modifying task dates. The Rust library also rejects scheduling through its FFI. This replaces the previous false-success echo response. Interactive chart moves, resizing, synchronization, and client-side critical-path visualization are separate features.

## Repeatable release gate (Linux)

Install Flutter/Dart, Rust/Cargo, Go, Node.js/npm, `protoc`, and Gitleaks 8.30.1. The gate is verified with Flutter 3.47.2 / Dart 3.13.2 and Rust 1.93.0; CI pins those releases. Minimum-SDK matrix testing is not yet included. The root workflow `.github/workflows/release-check.yml` provisions disposable PostgreSQL 15 and Redis 7 services and runs:

```bash
TEST_DB_PORT=<disposable-postgres-port> \
TEST_DB_PASS=<disposable-postgres-password> \
TEST_REDIS_PORT=<disposable-redis-port> \
bash scripts/check_release.sh
```

PostgreSQL must have user `dart_user` and database `legacy_gantt`. These integration tests create tenants and users; use isolated test services. The script scans current publishable files, tests the Rust FFI contract, protocol, admin app, widgets, and examples, runs the complete server suite serially, and builds the server, admin web app, and demo. Rust compilation finishes before Dart/Flutter builds. Historical scanning is a separate, redacted audit (`scripts/audit_open_source.py --history`) to verify published refs after the rewrite. The private recovery backup still contains the retired key and must not be published.

All six submodules are public, so recursive checkout uses the default read-only Actions token. The marketing site remains independent. Repository visibility is a separate release action.

The gate also checks Rust formatting and Clippy, the Go mock server's build/vet/formatting, package example analysis, plugin host lint and behavior tests, plugin webview startup and build. The Go mock has no automated tests. Tree grid and timeline examples have no test suites; their package tests and example analysis provide coverage.

Before the candidate versions reach pub.dev, run `python3 scripts/prepare_local_packages.py`. It writes ignored local overrides for the monorepo examples and dependent packages and refuses to overwrite conflicting user configuration. It runs automatically in the release gate. Independently cloned package repositories resolve published dependencies, so publish in protocol and timeline scrubber → chart → PERT order before relying on their standalone CI workflows.

## Fresh-checkout rehearsal

```bash
python3 scripts/create_release_checkout.py --output /tmp/gantt-release-candidate
cd /tmp/gantt-release-candidate/checkout
# Run the release gate with disposable services as above.
```

This copies tracked and nonignored source into temporary candidate repositories, creates local snapshot commits for each submodule and the root, and clones those exact commits with initialized submodules. It excludes ignored credentials and build caches. It does not commit or alter the working repository. This proves the current candidate is reproducible from Git objects; it does not prove that unpublished commits are accessible from public origins.

For publication, review and commit each changed submodule, push those commits, then commit the root with the resulting gitlinks. Verify an origin clone with `git clone --recurse-submodules <root-url>`, run the gate, and confirm all referenced repositories and commits are accessible to unauthenticated contributors. Publish package versions in dependency order and tag the reviewed commits. No publishing or visibility change is performed by the gate.

## Independent marketing site

The Zola site is maintained in its own repository and is not a server submodule.
An existing local `site/` checkout is preserved and ignored. Build the demo with
`bash scripts/build_demo.sh`; to copy it into a separate site checkout, pass
that checkout path as the first argument. Run `zola build` and
`zola check --skip-external-links` inside the site repository before deploying it.
EmailJS public identifiers in browser assets are visible to visitors; never put
a private EmailJS key, SMTP password, or mailbox credentials in the site.
