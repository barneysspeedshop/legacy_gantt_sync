#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROTOC_BIN=${PROTOC_BIN:-${PROTOC:-protoc}}
PROTOC_GEN_DART_BIN=${PROTOC_GEN_DART_BIN:-${PROTOC_GEN_DART:-protoc-gen-dart}}
CHECK_ONLY=0
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  CHECK_ONLY=1
fi

# The executable installed by `dart pub global activate` resolves `dart` from
# PATH.  Keep code generation on the SDK selected by the caller when an
# isolated SDK is supplied, rather than silently using a host Flutter SDK.
if [[ -n "${DART_BIN:-}" ]]; then
  if [[ "$DART_BIN" == */* ]]; then
    DART_BIN_DIR=$(cd "$(dirname "$DART_BIN")" && pwd)
  else
    DART_BIN_DIR=$(dirname "$(command -v "$DART_BIN")")
  fi
  export PATH="$DART_BIN_DIR:$PATH"
fi

PROTOC_BIN="$PROTOC_BIN" \
PROTOC_GEN_DART_BIN="$PROTOC_GEN_DART_BIN" \
  "$ROOT_DIR/scripts/check_proto_toolchain.sh"

GENERATED_DIR="$ROOT_DIR/legacy_gantt_protocol/lib/src/generated"
if (( CHECK_ONLY )); then
  GENERATED_OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/legacy-gantt-proto.XXXXXX")
  trap 'rm -rf -- "$GENERATED_OUTPUT_DIR"' EXIT
else
  GENERATED_OUTPUT_DIR="$GENERATED_DIR"
fi

"$PROTOC_BIN" \
  --plugin=protoc-gen-dart="$PROTOC_GEN_DART_BIN" \
  --dart_out=grpc:"$GENERATED_OUTPUT_DIR" \
  -I "$ROOT_DIR/legacy_gantt_protocol/proto" \
  "$ROOT_DIR/legacy_gantt_protocol/proto/gantt_protocol.proto"

if (( CHECK_ONLY )); then
  comparison_failed=0
  while IFS= read -r -d '' generated_file; do
    file_name=${generated_file##*/}
    expected_file="$GENERATED_DIR/$file_name"
    if [[ ! -f "$expected_file" ]]; then
      echo "Unexpected generated file: $file_name" >&2
      comparison_failed=1
    elif ! cmp -s "$generated_file" "$expected_file"; then
      echo "Generated file differs: $expected_file" >&2
      diff -u "$expected_file" "$generated_file" || true
      comparison_failed=1
    fi
  done < <(find "$GENERATED_OUTPUT_DIR" -maxdepth 1 -type f -name '*.dart' -print0)
  while IFS= read -r -d '' expected_file; do
    file_name=${expected_file##*/}
    if [[ ! -f "$GENERATED_OUTPUT_DIR/$file_name" ]]; then
      echo "Missing generated file: $expected_file" >&2
      comparison_failed=1
    fi
  done < <(find "$GENERATED_DIR" -maxdepth 1 -type f -name '*.dart' -print0)
  (( comparison_failed == 0 )) || exit 1
  echo "Dart protobuf generation matches checked-in files with protoc $("$PROTOC_BIN" --version | awk '{print $2}')."
else
  echo "Dart protobuf generated successfully with protoc $("$PROTOC_BIN" --version | awk '{print $2}')."
fi
