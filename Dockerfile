# Stage 1: Build Rust Solver
FROM rust:1.100.0@sha256:223cc32ddca8f3ee90c436dbc94b6b5f052ea7f9653c5201e9612f08ad7d21b8 AS rust-builder
COPY scripts/install_proto_toolchain.sh /tmp/install_proto_toolchain.sh
RUN apt-get update && apt-get install -y ca-certificates curl unzip \
    && SKIP_DART_PLUGIN=1 PROTO_TOOLCHAIN_DIR=/opt/gantt-proto bash /tmp/install_proto_toolchain.sh \
    && rm -rf /var/lib/apt/lists/*
ENV PROTOC=/opt/gantt-proto/protoc/bin/protoc
WORKDIR /app
COPY gantt_solver_rs ./gantt_solver_rs
COPY legacy_gantt_protocol ./legacy_gantt_protocol
WORKDIR /app/gantt_solver_rs
RUN cargo build --release --locked --jobs 1

# Stage 2: Build Dart Server (Forces Sequential Execution)
FROM dart:3.14.1@sha256:36176bf7b6400bdc4aa77ba07b733b2eabf22640f71afd1b83eba679a26d5698 AS dart-builder

# We copy a file from the previous stage here. This forces Docker to 
# wait for the Rust build to finish completely before starting the Dart build,
# preventing RAM contention on 1GB instances.
COPY --from=rust-builder /app/gantt_solver_rs/target/release/libgantt_solver_rs.so /tmp/libgantt_solver_rs.so

WORKDIR /app
COPY pubspec.* ./
COPY legacy_gantt_protocol ./legacy_gantt_protocol
RUN dart pub get --enforce-lockfile
COPY . .
RUN dart compile exe bin/server.dart -o bin/server

# Stage 3: Final Image
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

# Install CA certificates for HTTPS support
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

# Copy the compiled server binary
COPY --from=dart-builder /app/bin/server /app/bin/
COPY --from=dart-builder /app/docker/entrypoint.sh /app/bin/

# Copy the compiled Rust solver library to a system library path
COPY --from=rust-builder /app/gantt_solver_rs/target/release/libgantt_solver_rs.so /usr/lib/

# Set working directory to where the binary is
WORKDIR /app/bin

# Expose the server port
EXPOSE 8080

# Make entrypoint executable
RUN chmod +x entrypoint.sh

# Use the entrypoint script to load secrets before starting
ENTRYPOINT ["./entrypoint.sh"]
CMD ["./server"]
