#!/usr/bin/env bash
# Linux release checks; use disposable PostgreSQL and Redis services.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEST_DB_PORT:?Set the disposable PostgreSQL port}"
: "${TEST_DB_PASS:?Set the disposable PostgreSQL password}"
: "${TEST_REDIS_PORT:?Set the disposable Redis port}"
for tool in dart flutter cargo protoc go npm gitleaks; do
  command -v "$tool" >/dev/null || { echo "Missing release-check tool: $tool" >&2; exit 1; }
done

python3 scripts/prepare_local_packages.py
python3 scripts/audit_open_source.py
python3 scripts/check_state_ownership.py

# Finish Rust compilation before Dart/Flutter builds on memory-constrained hosts.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
(cd gantt_solver_rs && cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked && cargo build --release --locked)
export LD_LIBRARY_PATH="$PWD/gantt_solver_rs/target/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

(cd legacy_gantt_protocol && dart pub get && dart analyze --fatal-infos && dart test && dart pub publish --dry-run)
(cd legacy_gantt_protocol/reference_server_go && go test ./... && go vet ./... && test -z "$(gofmt -l .)")
dart pub get --enforce-lockfile
dart analyze --fatal-infos bin lib test
mkdir -p build
dart compile exe bin/server.dart -o build/release-server
dart test --concurrency=1

for package in config legacy_context_menu legacy_gantt_chart legacy_pert_chart legacy_tree_grid legacy_timeline_scrubber; do
  (cd "$package" && flutter pub get && flutter analyze --fatal-infos --fatal-warnings && flutter test)
done
for example in legacy_context_menu/example legacy_gantt_chart/example legacy_pert_chart/example legacy_tree_grid/example legacy_timeline_scrubber/example; do
  (cd "$example" && flutter pub get && flutter analyze --fatal-infos --fatal-warnings)
  if [[ -d "$example/test" ]]; then
    (cd "$example" && flutter test)
  fi
done
(cd integration_tests/canonical_sync && flutter pub get && flutter analyze --fatal-infos --fatal-warnings && flutter test)
(cd legacy_gantt_plugin && npm ci --ignore-scripts && npm test && npm run lint -- --max-warnings 0 && npm audit signatures && python3 scripts/test_audit_dependencies.py && python3 scripts/audit_dependencies.py)
(cd legacy_gantt_plugin/webview_ui && flutter pub get && flutter analyze --fatal-infos --fatal-warnings && flutter test && flutter build web --release --no-pub)
(cd config && flutter build web --release --no-pub)
bash scripts/build_demo.sh
echo 'Release checks passed (Rust scheduling remains explicitly unsupported).'
