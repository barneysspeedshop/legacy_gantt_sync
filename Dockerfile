# Stage 1: Build Rust Solver
FROM rust:latest AS rust-builder
WORKDIR /app
COPY gantt_solver_rs ./gantt_solver_rs
COPY legacy_gantt_protocol ./legacy_gantt_protocol
WORKDIR /app/gantt_solver_rs
RUN apt-get update && apt-get install -y protobuf-compiler
RUN cargo build --release

# Stage 2: Build Dart Server (Forces Sequential Execution)
FROM dart:stable AS dart-builder

# We copy a file from the previous stage here. This forces Docker to 
# wait for the Rust build to finish completely before starting the Dart build,
# preventing RAM contention on 1GB instances.
COPY --from=rust-builder /app/gantt_solver_rs/target/release/libgantt_solver_rs.so /tmp/libgantt_solver_rs.so

WORKDIR /app
COPY pubspec.* ./
COPY legacy_gantt_protocol ./legacy_gantt_protocol
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o bin/server

# Stage 3: Final Image
FROM debian:stable-slim

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
