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
1.  Both Client and Server compute a **Merkle Root** hash of their entire state (Tasks + Dependencies + Resources).
2.  The Client sends its Root to the Server.
3.  If the roots mismatch, the Server forces a **Full Sync** (reset) to get the Client back to a consistent state.

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
