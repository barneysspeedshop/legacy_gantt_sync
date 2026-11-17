# Licensing and Migration

All first-party components are MIT-licensed. Preserve the MIT copyright and permission notice and all third-party dependency notices.

The server no longer validates instance licenses, contacts a license service, issues trial licenses, or checks tenant license status. All authenticated, active tenants can synchronize without a license. Authentication, role checks, revocation, and tenant isolation still apply.

## Existing installations

- Remove `GANTT_LICENSE_KEY`, `GANTT_LICENSE_KEY_FILE`, and license secret mounts from deployment configuration.
- Remove the old license-only `ADMIN_SECRET` configuration and mounts. Admin endpoints continue to require role-authorized JWTs.
- The `/api/admin/license/*` endpoints and Config App license controls have been removed.
- Existing `licenses` tables are left untouched to preserve operator data. The server no longer creates, reads, or updates them. The local database inspector may still show historical rows with keys redacted.
- No external `SOLVER_API_KEY` is needed: scheduling uses the bundled Rust FFI solver.
- Configure unique database, JWT, Redis, and bootstrap superuser credentials. See [configuration](CONFIGURATION.md).

Contributors retain copyright; no assignment or commercial contributor agreement is required. Independently published submodules include their own MIT licenses.
