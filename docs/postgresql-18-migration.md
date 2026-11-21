# PostgreSQL 18 deployment prerequisite

The updated Compose and Swarm definitions use PostgreSQL 18.7, Redis 8.10.3, and Nginx 1.30.7 with immutable image digests. This source update does not upgrade a running deployment.

An existing PostgreSQL 15 volume cannot be opened directly by PostgreSQL 18. PostgreSQL 18 also changes the image's data layout. The volume now mounts at `/var/lib/postgresql`, with the database under its versioned subdirectory. Do not delete or initialize over the existing volume.

Before deploying the new database image:

1. Record the existing image digest and volume identity. Stop server writes and take a logical backup, including database roles. Keep the original database volume intact.
2. Restore the backup into a separate, empty PostgreSQL 18 volume using the new mount layout. Keep that service isolated from public clients while validating it.
3. Check schema objects, extensions, indexes, row counts, RLS policies, roles, and tenant access. Verify task, resource, dependency, and operation records and canonical Merkle roots. Run the server and two-client synchronization checks against the restored database.
4. Switch the server to the validated database during the maintenance window. Verify authentication, health, reset, reconnect, offline replay, and cross-client convergence before reopening traffic.
5. Retain the original volume and backup for rollback. Once clients write to the new database, rollback requires preserving those writes; simply switching to the old volume loses subsequent changes.

The disposable release suite tests PostgreSQL 18 and Redis 8. A synthetic dump/restore rehearsal provides additional evidence, but it does not replace validation of the deployment's own backup. Production migration and deployment remain separate release steps.
