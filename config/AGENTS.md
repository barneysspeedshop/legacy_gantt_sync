# AI Agent Instructions for `config/`

## Purpose

This is the **Config App** — an MIT-licensed Flutter desktop/web administrative UI for managing the `legacy_gantt_sync` server. It is **not published to pub.dev** and is part of the open-source ecosystem. Its sole purpose is to give a server operator a GUI for:

- Managing tenants (create, revoke, restore)
- Managing users within tenants (create, revoke, restore, kick active sessions)

The app is a thin client over the server's admin REST API and WebSocket push channel. Only server URLs are persisted in `SharedPreferences`. Access and local inspector tokens stay in memory and must be entered again after restarting the app. Stale persisted credentials from older versions are removed at startup.

---

## Architecture

```
config/lib/
  main.dart            — App entry point, login screen, dashboard, tenant/user screens
  api_service.dart     — All HTTP calls to the server REST API
  websocket_service.dart — WebSocket connection for real-time push updates
  models.dart          — Tenant and User data classes
```

The app is structured as a single-file Flutter app (`main.dart`) with four screens:

1. **LoginScreen** — collects Server URL, username, and password; calls `POST /auth/login`
2. **DashboardScreen** — entry point after login; currently only exposes "Manage Tenants"
3. **TenantListScreen** — lists all tenants; supports create, revoke, restore, and user management
4. **UserListScreen** — lists users for a given tenant; supports create, revoke, restore, and kick

---

## Server Endpoints Consumed

All calls go to a configurable `baseUrl` (default: `http://localhost:8080`). The app requires a running `legacy_gantt_sync` server.

### Auth Handler

| Method | Path | Purpose | Auth |
|--------|------|---------|------|
| `POST` | `/auth/login` | Obtain JWT access + refresh tokens | None |

### Tenant Handler (`/api/admin/tenants`)

| Method | Path | Purpose | Auth |
|--------|------|---------|------|
| `GET` | `/api/admin/tenants` | List all tenants | Bearer JWT |
| `POST` | `/api/admin/tenants` | Create tenant + initial admin user | Bearer JWT |
| `DELETE` | `/api/admin/tenants/:id` | Revoke (soft-delete) a tenant | Bearer JWT |
| `POST` | `/api/admin/tenants/:id/undelete` | Restore a revoked tenant | Bearer JWT |
| `GET` | `/api/admin/tenants/:id/users` | List users for a tenant | Bearer JWT |

### User Handler (`/api/users`)

| Method | Path | Purpose | Auth |
|--------|------|---------|------|
| `POST` | `/api/users` | Create a user in a tenant | Bearer JWT |
| `DELETE` | `/api/users/:id` | Revoke (soft-delete) a user | Bearer JWT |
| `POST` | `/api/users/:id/undelete` | Restore a revoked user | Bearer JWT |
| `POST` | `/api/users/:id/kick` | Force-disconnect an active session | Bearer JWT |

## WebSocket Push Updates

After login, the app connects to `ws://<host>/ws?token=<jwt>` (or `wss://` for HTTPS). The JWT is passed as a query parameter because the Flutter `web_socket_channel` package does not support custom upgrade headers on all platforms.

Messages use binary Protobuf `ProtocolMessage` frames from the shared protocol package. The app subscribes to two channels (logical payloads shown below):

| Channel | Subscribe message | Push event received | Effect |
|---------|------------------|---------------------|--------|
| `admin_updates` | `{"type":"subscribe","channel":"admin_updates"}` | `TENANT_LIST_UPDATE` | Refreshes tenant list |
| `tenant_users_<tenantId>` | `{"type":"subscribe","channel":"tenant_users_<tenantId>"}` | `USER_LIST_UPDATE` | Refreshes user list |

The WebSocket service auto-reconnects with a 2-second delay on disconnect and replays registered subscriptions after the connection is ready.

---

## Running Locally

### Prerequisites

- Flutter SDK (≥ 3.10)
- A running `legacy_gantt_sync` server (see root `docs/internal/DEV_GUIDE.md`)

### Steps

```bash
cd config
flutter pub get
flutter run -d linux   # or -d macos, -d windows, -d chrome
```

The login screen defaults to `http://localhost:8080`. Enter the configured operator username and password. HTTPS certificates are validated normally; install a trusted development CA when using a self-signed server.

## Fragile Areas

- **Tenant ID `system`**: The `system` tenant is the superuser's home tenant. The UI suppresses the delete button  for `tenant.id == 'system'`. Do not remove these guards.
- **Superuser protection**: The user list suppresses the revoke button for `username == 'superuser' && tenantId == 'system'`. This prevents locking yourself out. Do not remove this guard.
- **WebSocket subscribe timing**: `subscribeToAdminUpdates()` and `subscribeToTenantUsers()` are called from `initState` of their respective screens. Subscriptions must be retained until the WebSocket is ready and replayed on reconnect. Do not drop subscriptions registered before connection.
