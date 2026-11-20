# Server Architecture

## Overview

The Gantt Sync Server is a high-performance Dart backend designed to synchronize Gantt chart state across multiple clients in real-time. It uses a **Hybrid Logical Clock (HLC)** system combined with **Merkle Trees** to ensure eventual consistency and efficient delta synchronization.

## Core Components

### 1. CRDT & Database (`CrdtService`)
The server uses PostgreSQL not just as storage, but as the backing engine for a Conflict-free Replicated Data Type (CRDT).
*   **Tables**: `tasks`, `dependencies`, `resources`.
*   **Tenant Isolation**: All tables have **Row Level Security (RLS)** enabled. Operations are executed within a transaction that sets `app.current_tenant`, ensuring complete data isolation between tenants.
*   **Timestamps**: All modification timestamps are stored as Strings to support HLC format (providing causality tracking beyond wall-clock time).

### 2. Synchronization Engine
The sync protocol is designed to be offline-first and bandwidth-efficient.

#### Delta Sync
Clients transmit a `lastSynced` timestamp. The server queries for all records where `last_updated > lastSynced`.
*   **Batching**: Updates are streamed to the client in batches (e.g., 100 operations) via WebSocket.

#### Merkle Integrity Check (`MerkleService`)
To detect desyncs (where a client misses an update but thinks it's up to date), the system uses Merkle Trees.
1.  Both Client and Server compute a **Merkle Root** hash of their entire canonical state (tasks, dependencies, resources, and the reset fence), including causal clocks.
2.  The client requests the server root and compares it with its durable local state.
3.  A mismatch triggers reconciliation of canonical records, including tombstones. Synchronization replay does not issue the user-facing `RESET_DATA` command.

### 3. WebSocket Handler
Manages persistent connections.
*   **Authentication**: Validates JWTs issued by `AuthService`.
*   **Pub/Sub**: Uses Redis to broadcast updates to other server instances (for horizontal scaling), ensuring clients connected to different nodes still receive real-time updates.

## Data Model

### Resources
Resources are a hierarchical data structure.
*   **Schema**: `id`, `name`, `parent_id`, `is_expanded`, `gantt_type` ('person' or 'job').
*   **Hashing**: Resources contribute to the Merkle Root to ensuring staffing/assignments are consistent.

### Tasks & Dependencies
Standard Gantt data structures. Dependencies support `finishToStart`, `startToStart`, etc., and include `lag` times.

## Canonical local state and operation ownership

The persistent chart example owns one canonical CRDT state per tenant scope. Every local command commits canonical entities, derived SQLite read models, and durable outgoing operations atomically, then publishes one coherent snapshot to the UI. Network delivery happens after the local commit. Incoming live messages, initial replay, and Merkle recovery enter the same merge path. The widget receives presence traffic separately and does not independently reduce entity messages.

Tasks use per-field clocks and a presence register. Historical fields can merge while a task remains deleted; an older operation cannot override a newer deletion. Reset acts as a presence fence, including for records first seen after reset. Resources are complete LWW records, and resource/dependency tombstones carry canonical minimal payloads. The server serializes tenant reset and entity transactions with a PostgreSQL advisory transaction lock and applies the shared task merge engine before persisting and broadcasting accepted state.

The outgoing queue persists before any network send, even while connected. A successful WebSocket handoff removes the queue entry; there is no durable server acknowledgement in this protocol. To recover handoffs lost before server persistence, the persistent client reconciles both directions on connection: compare causal roots, atomically requeue canonical local records with their original clocks, flush, pull missing server state, and verify matching roots. Task field clocks, entity clocks, and the reset fence participate in hashing. Root and range requests use correlated responses; silence never establishes completion. Reconciliation is bounded and fails clearly if convergence cannot be verified. Tenant changes serialize with repair enqueueing to prevent cross-tenant work.
