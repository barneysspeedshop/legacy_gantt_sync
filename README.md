# Legacy Gantt Sync

The **Legacy Gantt Sync** repository contains the ecosystem for the `legacy_gantt_chart` Flutter package: the core Flutter packages, the Gantt Sync Server, and the VS Code extension. The marketing and documentation website is maintained separately.

## Repository Structure

This monorepo is organized into the following key components:

### Flutter Packages

The next breaking UI release uses standalone `material_ui`, Dart 3.13+, and Flutter 3.47+. See the [release and migration guide](docs/internal/RELEASE.md) for candidate versions and publication order. The pure-Dart protocol and server transport are unchanged.

- **[`legacy_gantt_chart`](legacy_gantt_chart/)**: The core Flutter widget for displaying interactive Gantt charts. Supports drag-and-drop, resizing, dynamic data loading, and CRDT-based synchronization.
- **[`legacy_tree_grid`](legacy_tree_grid/)**: A powerful, high-performance tree grid widget used by the Gantt chart to display the task list.
- **[`legacy_timeline_scrubber`](legacy_timeline_scrubber/)**: A dedicated timeline navigation widget that provides a high-level overview and helps users navigate large datasets.
- **[`legacy_pert_chart`](legacy_pert_chart/)**: A Flutter widget for rendering PERT (Program Evaluation and Review Technique) charts. Uses a custom `PertLayout` ranking engine to position nodes based on dependency graphs.
- **[`legacy_gantt_protocol`](legacy_gantt_protocol/)**: The open protocol specification and Dart client library for the Gantt Sync wire format. Defines all CRDT operation types, HLC timestamp semantics, and WebSocket message schemas. The specification (`SPEC.md`) and production server are MIT-licensed.

### VS Code Extension
- **[`legacy_gantt_plugin`](legacy_gantt_plugin/)**: A VS Code extension that embeds the Gantt chart as a Flutter Web webview panel inside the editor. The TypeScript extension host (`src/`) manages the VS Code lifecycle and message-passing; the Flutter Web app (`webview_ui/`) renders the chart. This is a prototype with mock data: its JSON sync client has not been migrated to the production binary Protobuf transport.

### Backend Infrastructure
- **[`bin/server.dart`](bin/server.dart)**: The entry point for the **Gantt Sync Server**.
- **`lib/`**: Contains the server-side logic, including:
  - **Shelf**-based HTTP server.
  - **PostgreSQL** integration for persistent storage.
  - **Redis** for pub/sub messaging and state synchronization.
- **[`gantt_solver_rs`](gantt_solver_rs/)**: An experimental Rust scheduling library. Optimization is not implemented; scheduling requests return an explicit error. Loaded by the Dart server via FFI at runtime. This component is MIT-licensed.

### Admin Application
- **[`config`](config/)**: A MIT-licensed Flutter administrative UI for managing tenants and users through the server REST API.

### Documentation
- **[Website](https://gantt-sync.com)**: Marketing and documentation, maintained in a separate repository and deployment.
- **[`docs/internal/`](docs/internal/)**: Internal developer documentation.
  - [Architecture & Sync Protocol](docs/internal/ARCHITECTURE.md)
  - [Server Configuration](docs/internal/CONFIGURATION.md)
  - [Licensing and Migration](docs/internal/LICENSING.md)
  - [Developer Guide](docs/internal/DEV_GUIDE.md)

### Legacy Components
- **[`google_cloud_function`](google_cloud_function/)**: A legacy Python Google Cloud Function that used OR-Tools for schedule optimization. This was the previous external solver and is **not part of the current deployment stack**. The current production path uses the embedded Rust FFI solver (`gantt_solver_rs`). Retained for historical reference.

## Getting Started

### Prerequisites
- [Flutter SDK](https://flutter.dev/docs/get-started/install)
- [Dart SDK](https://dart.dev/get-dart)
- [Docker](https://www.docker.com/) (optional, for running the full stack)

### Running the Example App
To see the Gantt chart in action, run the example application provided in the `legacy_gantt_chart` package.

```bash
git submodule update --init --recursive
python3 scripts/prepare_local_packages.py
cd legacy_gantt_chart/example
flutter pub get
flutter run
```

### Running the Gantt Sync Server

#### Using Dart SDK
You can run the server directly using the Dart SDK. Ensure you have a PostgreSQL database and Redis instance running locally.

```bash
dart run bin/server.dart
```

#### Using Docker Swarm
This infrastructure is designed to be deployed using **Docker Swarm** for production-grade reliability.

1. **Initialize Swarm** (if not already done):
   ```bash
   docker swarm init
   ```

2. **Create Secrets & Configs**:
   Create `secrets/db_password.txt` and `secrets/jwt_secret.txt` locally with unique, randomly generated values. These files are ignored by Git and Docker builds. Set `REDIS_PASSWORD`, `SUPERUSER_USERNAME`, and `SUPERUSER_PASSWORD` in your deployment environment. Do not reuse example or test credentials.
   ```bash
   mkdir -p secrets
   (umask 077; openssl rand -hex 32 > secrets/db_password.txt)
   (umask 077; openssl rand -hex 32 > secrets/jwt_secret.txt)
   docker config create nginx_conf nginx/nginx.conf
   ```

3. **Deploy the Stack**:
   ```bash
   docker stack deploy -c docker-swarm.yml legacy_gantt
   ```

This will deploy the following services:
- **`server`**: The Gantt Sync API.
- **`db`**: PostgreSQL 15.
- **`redis`**: Redis 7.
- **`nginx`**: Reverse proxy handling TLS and routing.

## Infrastructure
The repository also contains configuration for deployment:
- **`docker-swarm.yml`**: Configuration for deploying to a Docker Swarm cluster.
- **`.github/workflows/`**: CI/CD pipelines for testing and deployment.

## License

All first-party components are licensed under the [MIT License](LICENSE), including the production server, Rust solver, Config App, VS Code extension, protocol, widgets, and website. There are no commercial editions, trial periods, license keys, or feature gates. Contributors retain copyright to their contributions, which are accepted under MIT. Preserve dependency licenses and third-party notices.

See [release versions, migration, and repeatable checks](docs/internal/RELEASE.md).

See [migration notes](docs/internal/LICENSING.md) and [security guidance](SECURITY.md) before publishing or deploying.
