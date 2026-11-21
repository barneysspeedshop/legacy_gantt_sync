#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_PROTOC_VERSION=${PROTOC_VERSION:-36.2}
EXPECTED_PROTOC_PLUGIN_VERSION=${PROTOC_PLUGIN_VERSION:-25.1.0}
PROTOC_BIN=${PROTOC_BIN:-${PROTOC:-protoc}}
PROTOC_GEN_DART_BIN=${PROTOC_GEN_DART_BIN:-${PROTOC_GEN_DART:-protoc-gen-dart}}

command -v "$PROTOC_BIN" >/dev/null 2>&1 || {
  echo "protoc executable not found: $PROTOC_BIN" >&2
  exit 1
}
command -v "$PROTOC_GEN_DART_BIN" >/dev/null 2>&1 || {
  echo "protoc-gen-dart executable not found: $PROTOC_GEN_DART_BIN" >&2
  exit 1
}

actual_protoc_version=$("$PROTOC_BIN" --version)
expected_protoc_version="libprotoc $EXPECTED_PROTOC_VERSION"
if [[ "$actual_protoc_version" != "$expected_protoc_version" ]]; then
  echo "expected $expected_protoc_version, got $actual_protoc_version" >&2
  exit 1
fi

plugin_version=$(sed -n 's/^# Version: //p' "$PROTOC_GEN_DART_BIN" | head -n 1)
if [[ "$plugin_version" != "$EXPECTED_PROTOC_PLUGIN_VERSION" ]]; then
  echo "expected protoc_plugin $EXPECTED_PROTOC_PLUGIN_VERSION, got ${plugin_version:-unknown}" >&2
  exit 1
fi
if ! grep -q '^# Package: protoc_plugin$' "$PROTOC_GEN_DART_BIN"; then
  echo "protoc-gen-dart is not the protoc_plugin executable" >&2
  exit 1
fi

printf 'protoc %s\n' "$actual_protoc_version"
printf 'protoc_plugin %s\n' "$plugin_version"
