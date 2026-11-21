# Latest stable migration

Target snapshot: 2026-11-21. Production deployment and package publication are separate release steps.

## Plan

- [x] Read the Principles section of poteto-mode.
- [x] Phase A: Frame. Inventory tracked manifests and official release metadata.
- [x] Phase B: Design the workflow. Capture baseline versions and install isolated toolchains.
- [x] Phase C: Run the loop. Upgrade each component and verify its behavior.
- [x] Phase D: Keep the audit trail. Record decisions and evidence as units complete.
- [ ] Phase E: Verify and hand back. Run the full ecosystem release gates.

The upgrade covers the server, seven submodules, their examples, configuration app, Rust solver, Go reference server, CI toolchains, and deployment image declarations. The detached marketing repository is checked separately for build tool versions and demo compatibility.

The completion gate is successful tests, zero warnings or informational lint findings, release builds, security checks, and package checks with published dependency resolution. A dependency that cannot resolve at its latest stable version must have an evidenced compatibility explanation. No prerelease versions qualify.

Independent work partitions are the plugin TypeScript host, Rust and Go components, and Dart/Flutter packages. The coordinator owns shared CI configuration, SDK installation, the frozen inventory, and integration verification. Each delegate owns a separate repository or explicit nonoverlapping files.

Database major versions require migration testing against a copy of representative data. Changing an image tag alone does not prove an existing production volume can upgrade.

## Initial targets

| Toolchain | Stable target |
| --- | --- |
| Flutter | 3.50.1 |
| Flutter bundled Dart | 3.14.0 |
| Standalone Dart server | 3.14.1 |
| Node.js LTS | 26.13.1 |
| Rust | 1.100.0 |
| Go | 1.27.4 |
| Python | 3.15.2 |
| Protobuf compiler | 36.2 |
| Dart protobuf generator | 25.1.0 |
| Marketing site Zola | 0.23.6 |
| Android Gradle Plugin | 9.5.2 |
| Gradle | 9.9.2 |
| Kotlin | 2.4.21 |
| Temurin JDK | 27.0.1.1+4 |
| Marketing contact EmailJS SDK | 5.0.3 |

Version targets come from official release feeds. Local test SDKs live under `/tmp/gantt-latest-sdks` so the shared developer SDK remains untouched.

## Compatibility limits

TypeScript 7.0.2 is the newest stable compiler, but the newest stable `typescript-eslint` parser explicitly rejects it and declares TypeScript `<6.1.0`. The plugin uses supported TypeScript 6.0.3 with the newest stable ESLint and parser. No peer-dependency override or lint suppression bypasses this limit.

Transitive Pub dependencies follow the newest versions allowed by their upstream packages and Flutter SDK pins. `sql_crdt` and `sqlite_crdt` constrain `sqlparser`; Flutter pins `test_api` and `material_color_utilities`; `file_selector` constrains `cross_file`. The upgrade does not force incompatible transitive overrides.

For the detached marketing site, set Cloudflare Pages `ZOLA_VERSION=0.23.6` in both production and preview build environments when deploying the prepared site update. Cloudflare selects this tool through its build environment; changing site source does not change that provider setting. The site migration remains compatible with the preceding Zola version while deployment is coordinated.

See [PostgreSQL 18 migration](postgresql-18-migration.md) before updating an existing database deployment. No production data or runtime has been changed by this migration work.
