#!/bin/bash
set -e
export PATH="$PATH:$HOME/.pub-cache/bin"
protoc --dart_out=grpc:legacy_gantt_protocol/lib/src/generated -I legacy_gantt_protocol/proto legacy_gantt_protocol/proto/gantt_protocol.proto
echo "Dart protobuf generated successfully."
