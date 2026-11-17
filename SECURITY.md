# Security and publication

The complete first-party ecosystem is MIT-licensed. Authentication and tenant isolation remain required. Never publish operator credentials, customer datasets, database dumps, or private TLS keys.

## Credential audit (2026-11-17)

A local Gitleaks scan covered publishable working files and all local Git refs in the main repository and seven initialized submodules. A committed RSA licensing private key was found at `keys/private_key.pem` (introduced in commit `97b20e9e7ee1`). The keypair has been removed from tracking and licensing code has been removed. Local ignored copies remain operator-owned.

The key no longer grants anything on the updated server because its only known purpose was signing licenses and all license validation has been removed. Its exposure does not imply exposure of the separate JWT signing secret, database passwords, or TLS keys. If the RSA key was reused outside licensing or remains trusted by an older deployment, retire it there. Historical cleanup is optional for an exclusively retired licensing key; removing the file from tracking does not remove earlier copies in history, clones, forks, artifacts, or images. The server repository has a single initial commit for the open-source release. A local recovery backup retains the previous history. This does not revoke copied keys, remove external clones or caches, rotate deployed credentials, or change repository visibility.

The other history finding was a truncated JWT header example in `server_interaction.md`, not a usable signed access token. The current example uses an explicit placeholder. No other credentials were detected by Gitleaks in the scanned local refs. A manual review also found shared sample-account passwords in the seeding CLI and chart examples, including an example aimed at the hosted API. Those defaults have been removed from source. Reset or disable any deployed accounts created with the former seed defaults, and replace previously published demo bundles before redeploying them. The separate marketing site's demo bundle has been rebuilt from the sanitized source. This does not cover remote-only refs not fetched locally, GitHub Actions secrets, releases, container registries, CI logs, LFS payloads, or deployed systems, and is not a guarantee that no secrets exist.

## Deployment and local tools

- Supply unique database, JWT, Redis, and bootstrap superuser secrets. Compose and Swarm no longer offer shared password or JWT defaults. Test credentials are fixtures only.
- Keep `keys/`, `secrets/`, `.env*`, and private certificates out of Git and Docker contexts. Existing images built before these exclusions may contain credentials in their layers; inspect and retire affected artifacts.
- Production runs behind TLS. The Config App validates server certificates and keeps session credentials in memory. Restarting requires login and re-entering the local inspector token. Older persisted credentials are removed at startup.
- Access logs omit query strings and Referer URLs; Config App debug output omits the WebSocket URL and transport error details that may contain JWTs. Restrict access to proxy error logs, which may include request URLs on upstream failures, and configure the hosting platform's logging appropriately.
- The token-generation CLI deliberately emits a token to stdout. Redirect it to a protected destination, never a shared log. The data-seeding CLI requires credentials in environment variables and does not print passwords.
- The local database inspector is a separate loopback-only process protected by both an operator token and a superuser JWT. Do not expose it through a public proxy. Historical license rows are read-only and their keys remain redacted.
- The Go reference server uses mock authentication for protocol testing. Do not deploy it as an authenticated production service.

## Repeatable local scan

Install Gitleaks v8, then run from the repository root:

```bash
python3 scripts/audit_open_source.py
python3 scripts/audit_open_source.py --history
```

The script discovers initialized submodules from Git's index, scans tracked and non-ignored untracked files, and optionally scans every local ref. It prints only file locations, rule identifiers, and commit IDs. It exits nonzero for findings or scanner failures. After the intentional history rewrite, the public server refs should scan clean; local recovery backups still contain the former key and must remain private.
