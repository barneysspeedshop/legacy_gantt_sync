# Coordinated open-source release

## Material UI migration candidates

This is a separate breaking release after the initial MIT/open-source release. The new UI versions are candidates; protocol 3.0.1 stays unchanged.

| Package | Candidate | Requirement |
| --- | --- | --- |
| `legacy_gantt_protocol` | 3.0.1 (unchanged) | Existing pure-Dart protocol; no republish needed |
| `legacy_context_menu` | 3.0.0 | Dart 3.13 / Flutter 3.47 or newer; standalone Material UI |
| `legacy_tree_grid` | 0.15.0 | Dart 3.13 / Flutter 3.47 or newer; standalone Material UI |
| `legacy_timeline_scrubber` | 4.0.0 | Same Flutter baseline; standalone Material UI |
| `legacy_gantt_chart` | 10.0.0 | Same Flutter baseline; protocol ^3.0.1 and timeline ^4.0.0 |
| `legacy_pert_chart` | 0.3.0 | Same Flutter baseline; chart ^10.0.0 and protocol ^3.0.1 |

The server and Config App retain their own application versions. The plugin remains a prototype; its JSON sync client is not compatible with the production binary transport.

### Application migration

Add `material_ui` to applications that use Material design and replace `package:flutter/material.dart` imports with `package:material_ui/material_ui.dart`. SDK Material types and standalone Material types are distinct, so migrate callers and their theme arguments together. Use the standalone package's `GlobalMaterialLocalizations.delegates`. The context menu is migrated in the same release, so the examples use the standalone types directly without a compatibility bridge.

Keep existing installations on chart 9.x if they need the previous Flutter baseline. This migration is not a 9.0.x patch. The pure-Dart protocol, CRDT clocks, and server wire format remain unchanged.

Publish **context menu 3.0.0, tree grid 0.15.0, and timeline 4.0.0 first**, then verify and publish **chart 10.0.0**, then verify and publish **PERT 0.3.0**. Chart and tree examples also resolve context menu; publish it before rerunning their standalone CI. Recheck standalone CI against hosted dependencies after each prerequisite is available; monorepo path overrides are only for candidate validation. Package publication is an explicit maintainer action.

## Migration

The preceding open-source release used protocol 3.0.1, timeline 3.0.0, chart 9.0.0, and PERT 0.2.0. Protocol 3.0.1 corrected equal-clock tombstone handling found after 3.0.0 was published; the next release retains that minimum.

Upgrade production clients and server together: there is no JSON-text fallback on the production WebSocket endpoint. Use `ProtocolMessage` binary frames and `ProtobufMapper` for logical operation maps. The Go mock server still uses JSON and is not a production compatibility target.

The timeline scrubber now supports date-time and line-count modes, so its public task/widget date fields and date callbacks are nullable. Date-only consumers should select date-time mode and narrow nullable fields before use. The new release also fixes pointer-down drag initiation and padding preservation on zoom reset.

The protocol package now exports generated Protobuf models. Construct them with generated setters or factory fields. Task dates are UTC ISO-8601 strings, model clocks are serialized HLC strings, dependency lag uses `Int64`, and arbitrary metadata is encoded in `metadataJson`. Use `parsedLastUpdated` when an `Hlc` object is needed. Chart domain models still expose `DateTime` and `Hlc` and convert at the protocol boundary. Batch task records represent upserts, so decoded insert/update records use `UPDATE_TASK`; deletion markers and per-record clocks are preserved.

All first-party components use MIT. Keep authentication, tenant isolation, revocation, and third-party notices. The retired licensing key remains in historical commits; see [SECURITY.md](../../SECURITY.md) and [licensing migration](LICENSING.md).

**Rust scheduling is experimental and unsupported.** `OPTIMIZE_SCHEDULE` now returns an explicit error without modifying task dates. The Rust library also rejects scheduling through its FFI. This replaces the previous false-success echo response. Interactive chart moves, resizing, synchronization, and client-side critical-path visualization are separate features.

## Repeatable release gate (Linux)

Install Flutter/Dart, Rust/Cargo, Go, Node.js/npm, `protoc`, and Gitleaks 8.30.1. CI targets Flutter 3.50.0 to match the SDK that reports the old Material imports as deprecated. Local migration checks use Flutter 3.47.2 / Dart 3.13.2 for the new baseline. Rust remains pinned to 1.93.0. Exact minimum-patch matrix testing is not included. The root workflow `.github/workflows/release-check.yml` provisions disposable PostgreSQL 15 and Redis 7 services and runs:

```bash
TEST_DB_PORT=<disposable-postgres-port> \
TEST_DB_PASS=<disposable-postgres-password> \
TEST_REDIS_PORT=<disposable-redis-port> \
bash scripts/check_release.sh
```

PostgreSQL must have user `dart_user` and database `legacy_gantt`. These integration tests create tenants and users; use isolated test services. The script scans current publishable files, tests the Rust FFI contract, protocol, admin app, widgets, and examples, runs the complete server suite serially, and builds the server, admin web app, and demo. Rust compilation finishes before Dart/Flutter builds. Historical scanning is a separate, redacted audit (`scripts/audit_open_source.py --history`) to verify published refs after the rewrite. The private recovery backup still contains the retired key and must not be published.

All seven submodules are public, so recursive checkout uses the default read-only Actions token. The marketing site remains independent. Repository visibility is a separate release action.

The gate also checks Rust formatting and Clippy, the Go mock server's build/vet/formatting, package example analysis, plugin host lint and behavior tests, plugin webview startup and build. The Go mock has no automated tests. Tree grid and timeline examples have no test suites; their package tests and example analysis provide coverage.

Before the candidate versions reach pub.dev, run `python3 scripts/prepare_local_packages.py`. It writes ignored local overrides for the monorepo examples and dependent packages and refuses to overwrite conflicting user configuration. It runs automatically in the release gate. Independently cloned package repositories resolve published dependencies, so publish the new context menu, tree grid, and timeline scrubber → chart → PERT versions in order before relying on their standalone CI workflows. The protocol package is unchanged.

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
