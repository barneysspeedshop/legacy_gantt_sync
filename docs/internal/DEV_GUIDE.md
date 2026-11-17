# Developer Guide

## Running the Server Locally

For local development, use the provided helper script. It handles starting dependent services (Postgres, Redis) via Docker Compose and running the Dart server with the correct environment variables.

### Prerequisites
*   Docker & Docker Compose
*   Dart SDK
*   Rust toolchain and `protoc` when running the Dart server outside Docker. Build the solver first with `cargo build --release --manifest-path gantt_solver_rs/Cargo.toml`; Docker builds it automatically.

### Quick Start
Run from the root of the repo:

```bash
./scripts/run_dev_server.sh
```

**What this does:**
1.  Starts or reuses this Compose project's `db` and `redis` services. If another project owns ports 5432 or 6379, startup fails without stopping that project.
2.  Waits for the database to be healthy.
3.  Runs `dart bin/server.dart` with:
     *   `DB_PASS`, `JWT_SECRET`, `SUPERUSER_USERNAME`, and `SUPERUSER_PASSWORD` supplied by the shell environment (required)
     *   `LOCAL_INSPECTOR_TOKEN` supplied by the shell environment (required)

The same command starts the local database inspector on `127.0.0.1:8787`.
Set the token before starting it:

```bash
export LOCAL_INSPECTOR_TOKEN='choose-a-local-only-token'
./scripts/run_dev_server.sh
```

The inspector API is documented in `docs/internal/local_inspector_openapi.yaml`.

### Admin Access
Admin API access requires a JWT obtained by logging in with the configured superuser credentials. There is no shared admin secret.

## Running the Config App
The **Config App** is the administrative UI for managing tenants and users.

```bash
cd config
flutter run -d linux
```
*Note: Ensure the server is running first.*

## Key Locations
*   **API Handlers**: `lib/server/handlers/`
*   **Database Schema**: Managed via `CrdtService` and `AuthService` init methods.

## WebSocket authentication integration check

Use disposable PostgreSQL and Redis services, with PostgreSQL user `dart_user` and database `legacy_gantt`. Supply their loopback ports and test password explicitly; the test creates tenants and users. Build the Rust solver first as described above.

```bash
TEST_DB_PORT=<postgres-test-port> \
TEST_DB_PASS=<disposable-test-password> \
TEST_REDIS_PORT=<redis-test-port> \
dart test test/websocket_auth_test.dart
```

The check exercises login, binary Protobuf subscriptions, and rejection of missing or invalid authentication. Do not point it at a production database.
