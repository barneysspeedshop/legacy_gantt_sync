# AI Agent Instructions for Legacy Gantt Sync

Welcome. If you are an AI assistant or autonomous coding agent reading this file, it means you have been tasked with working on the `legacy_gantt_sync` repository. 

> [!IMPORTANT]  
> READ THIS CAREFULLY before proposing architectural changes or trying to build the project.

## 1. Monorepo Architecture Overview
This is a comprehensive monorepo for a high-performance Gantt chart synchronization ecosystem. It contains multiple sub-projects with a mixed tech-stack:
- **Frontend / Client**: Dart & Flutter packages (`legacy_gantt_chart`, `legacy_tree_grid`, etc.)
- **Backend / Server**: Dart-based HTTP server using `shelf` (`bin/` and `lib/`), PostgreSQL for CRDT data backing, Redis for pub/sub, and an isolated Rust-based solver (`gantt_solver_rs`).

## 2. Gantt Sync Server Protocol (CRDT & WebSocket)
The backend HTTP/WebSocket server located in `lib/` and `bin/` powers real-time UI synchronization utilizing a `postgres_crdt` structural approach.

### Synchronization Topology
The system is built on **Conflict-free Replicated Data Types (CRDTs)** and relies on eventual consistency. 
- Do not implement raw "last write wins" updates assuming typical CRUD operations. 
- The system scales by broadcasting operations packed with **Hybrid Logical Clocks (HLC)** to ensure strict causality orders across node boundaries.
- To detect dropped broadcast packets, clients and servers frequently exchange root hashes derived from **Merkle Trees**. A mismatch triggers a "Full Sync". If you add new data fields to tasks, resources, or dependencies, you **MUST** ensure they are hashed deterministically in the Merkle Tree function, otherwise you will trigger infinite sync loops.

### WebSocket Connections
- **Auth Handshake**: The server anticipates a JSON Web Token (JWT) provided on the WebSocket upgrade request. Browser APIs (like Chrome Web WASM) generally lack support for injecting custom WSS headers, necessitating URL or cookie-bound workarounds.
- **Tenant Subscription Flow**: After upgrading, clients push a `{"type": "subscribe", "channel": "<tenant_id>"}` message payload. The server natively responds by flushing all pre-existing table operations for that isolated tenant.
- **Network Pub/Sub**: Incoming entity updates (e.g. `{"type": "UPDATE_TASK", "data": {...}}`) are injected via Redis into an internal event bus, assuring all horizonal cluster nodes independently relay updates to their specific connected sockets. 

## 3. Deployment Constraints (Oracle Docker Swarm)
This system is deployed via Docker Swarm to extremely robust but hardware-constrained edge environments (1GB Oracle instances).

### Build Limits
> [!WARNING]
> Compiling the decoupled Rust solver in conjunction with the Dart backend inside a massive Docker context triggers severe memory starvation out-of-memory limits. Modifications to the `Dockerfile` or `docker-swarm.yml` MUST guarantee sequential, layered build processes and aggressive Context Directory pruning (`.dockerignore`).

### Configuration Loading
- All configurations are initialized strictly through environments (e.g. `LEGACY_GANTT_SYNC_PORT`, `JWT_SECRET`, `DB_HOST`). 
- Superuser overrides or `ADMIN_SECRET` keys dynamically interpret raw string overrides or absolute Docker secret file paths (`/run/secrets/xxx`), streamlining the Swarm architecture.

## 4. Searching for Context
Many sub-directories also have their own targeted `AGENTS.md` files (specifically `lib/`, `legacy_gantt_chart/`, `legacy_tree_grid/`, `gantt_solver_rs/`, `legacy_gantt_plugin/`, `legacy_gantt_protocol/`, etc). Please query those directories for extremely localized, domain-specific instructions.
