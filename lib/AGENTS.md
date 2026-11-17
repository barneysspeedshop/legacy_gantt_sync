# AI Agent Instructions for Gantt Sync Server (Backend)

The files contained herein (and in `../bin/`) cover the high-performance Dart WebSocket synchronization server.

## Architectural Requirements

### 1. Merkle Tree Stability
> [!IMPORTANT]
> To verify offline-first synchronization parity, the server generates a Merkle Root Hash based on Tasks, Resources, and Dependencies. If you add, remove, or modify a field on any of these core entities, **ensure the properties are included deterministically in the Merkle hashing function**, and the hashing function matches the Client implementation. Otherwise, clients will suffer from perpetual full-sync resets.

### 2. Multi-tenant Safety and RLS (Row-Level Security)
Do not write custom SQL statements injecting tenant variables directly if it can be avoided. 
All tables run under PostgreSQL Row Level Security (RLS). When the server executes queries, it wraps operations in transactions that set `app.current_tenant`. This is the sole mechanism ensuring data isolation between distinct customer datasets. Maintain this boundary stringently.

### 3. Server-side State Resets
When a client triggers a Merkle root mismatch, the server will force a state reset. This reset logic must remain **atomic** and buffer correctly, transmitting batched entities to the client securely. 
