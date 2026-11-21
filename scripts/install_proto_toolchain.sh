#!/usr/bin/env bash
set -Eeuo pipefail

PROTOC_VERSION=${PROTOC_VERSION:-36.2}
PROTOC_PLUGIN_VERSION=${PROTOC_PLUGIN_VERSION:-25.1.0}
TOOLCHAIN_ROOT=${PROTO_TOOLCHAIN_DIR:-${RUNNER_TEMP:-/tmp}/gantt-proto-toolchain}
SKIP_DART_PLUGIN=${SKIP_DART_PLUGIN:-0}

if [[ "$PROTOC_VERSION" != 36.2 || "$PROTOC_PLUGIN_VERSION" != 25.1.0 ]]; then
  echo "This installer is pinned to protoc 36.2 and protoc_plugin 25.1.0" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64)
    archive_name="protoc-36.2-linux-x86_64.zip"
    archive_sha256="121f6c7afe1d4d0e3ea6aab9432038599250134cbf4474cb1167d2c7decd4278"
    ;;
  aarch64|arm64)
    archive_name="protoc-36.2-linux-aarch_64.zip"
    archive_sha256="8b8f18bd2b30346efbc698dd5a73dd7c805f3ef8380f6dfc95c768f3f1852f6a"
    ;;
  *)
    echo "Unsupported Linux architecture for protoc 36.2: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$TOOLCHAIN_ROOT/downloads" "$TOOLCHAIN_ROOT/protoc"
archive="$TOOLCHAIN_ROOT/downloads/$archive_name"
verify_archive() {
  local candidate=$1
  printf '%s  %s\n' "$archive_sha256" "$candidate" | sha256sum --check --status
}

if [[ -f "$archive" ]] && ! verify_archive "$archive"; then
  echo "Discarding checksum-mismatched cached archive: $archive" >&2
  rm -f -- "$archive"
fi
download_tmp=
trap 'if [[ -n "${download_tmp:-}" ]]; then rm -f -- "$download_tmp"; fi' EXIT
if [[ ! -f "$archive" ]]; then
  download_tmp=$(mktemp "$TOOLCHAIN_ROOT/downloads/.${archive_name}.XXXXXX")
  curl --fail --location --silent --show-error \
    "https://github.com/protocolbuffers/protobuf/releases/download/v36.2/$archive_name" \
    --output "$download_tmp"
  verify_archive "$download_tmp"
  mv -f -- "$download_tmp" "$archive"
  download_tmp=
fi
unzip -oq "$archive" -d "$TOOLCHAIN_ROOT/protoc"

PROTOC_BIN="$TOOLCHAIN_ROOT/protoc/bin/protoc"
[[ "$("$PROTOC_BIN" --version)" == "libprotoc 36.2" ]] || {
  echo "protoc installation did not produce libprotoc 36.2" >&2
  exit 1
}

PROTOC_GEN_DART_BIN=
if [[ "$SKIP_DART_PLUGIN" != 1 ]]; then
  DART_BIN=${DART_BIN:-dart}
  DART_HOME=${DART_HOME:-$TOOLCHAIN_ROOT/dart-home}
  PUB_CACHE=${PUB_CACHE:-$TOOLCHAIN_ROOT/pub-cache}
  mkdir -p "$DART_HOME" "$PUB_CACHE"
  HOME="$DART_HOME" PUB_CACHE="$PUB_CACHE" "$DART_BIN" pub global activate protoc_plugin 25.1.0
  PROTOC_GEN_DART_BIN="$PUB_CACHE/bin/protoc-gen-dart"
  test -x "$PROTOC_GEN_DART_BIN"
fi

printf 'PROTOC_BIN=%s\n' "$PROTOC_BIN"
printf 'PROTOC_VERSION=%s\n' "$PROTOC_VERSION"
if [[ -n "$PROTOC_GEN_DART_BIN" ]]; then
  printf 'DART_BIN=%s\n' "$DART_BIN"
  printf 'PROTOC_GEN_DART=%s\n' "$PROTOC_GEN_DART_BIN"
  printf 'PROTOC_PLUGIN_VERSION=%s\n' "$PROTOC_PLUGIN_VERSION"
fi
