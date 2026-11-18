# Security and publication

The complete first-party ecosystem is MIT-licensed. Authentication and tenant isolation remain required. Never publish operator credentials, customer datasets, database dumps, or private TLS keys.

## Credential audit (2026-11-17)

A local Gitleaks scan covered publishable working files and all local Git refs in the main repository and seven initialized submodules. A committed RSA licensing private key was found at `keys/private_key.pem` (introduced in commit `97b20e9e7ee1`). The keypair has been removed from tracking and licensing code has been removed. Local ignored copies remain operator-owned.

The key no longer grants anything on the updated server because its only known purpose was signing licenses and all license validation has been removed. Its exposure does not imply exposure of the separate JWT signing secret, database passwords, or TLS keys. If the RSA key was reused outside licensing or remains trusted by an older deployment, retire it there. Historical cleanup is optional for an exclusively retired licensing key; removing the file from tracking does not remove earlier copies in history, clones, forks, artifacts, or images. The server repository history was replaced with a clean initial commit for the open-source release. A local recovery backup retains the previous history. This does not revoke copied keys, remove external clones or caches, rotate deployed credentials, or change repository visibility.

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

## Repository contribution controls

Changes to `main` require an up-to-date passing `verify` check from GitHub Actions, one approving review, code-owner review, and resolved review conversations. New commits dismiss stale approvals. Normal merges use squash commits; force pushes and branch deletion are blocked. `@barneysspeedshop` owns all paths. The sole maintainer retains the administrator override for recovery and maintainer-authored pull requests.

Actions tokens default to read-only and cannot approve pull requests. Workflows use immutable action commits, selected action providers, and no cross-repository checkout secret. Dependabot proposes action updates through pull requests. Private-fork workflows are disabled and cannot receive secrets or write tokens. All outside-contributor workflows require approval. Never run unreviewed contributor code with deployment or publishing credentials.


## Supply-chain controls

All eight public repositories require a reviewed pull request, code-owner approval, resolved conversations, and current GitHub Actions checks on main. Force pushes and branch deletion are disabled. The existing sole-maintainer administrator override remains available; protecting the maintainer account is therefore essential.

Owned workflow references use immutable action commits, checkout does not retain Git credentials, and build/test jobs have read-only repository tokens. Static demo builds and gh-pages publishing run on separate runners. Only the publishing job receives contents-write permission, and it only downloads and publishes the static artifact. Coverage jobs retain their reports without committing directly to main. Workflows never receive package-publishing or cloud credentials.

The plugin disables npm lifecycle scripts in both project configuration and installation commands. Unused Mocha, glob, and Electron test dependencies are removed. Its compile/lint/test sequence stays explicit; npm publication of the VS Code project is disabled. CI checks registry signatures and advisories. Signatures prove registry origin, not that the publisher's code is harmless. Lockfile hashes and signatures must be combined with review, containment, and limited credentials.

One upstream issue is still open: [picomatch ReDoS GHSA-fc5q-39xc-vjpf](https://github.com/advisories/GHSA-fc5q-39xc-vjpf), affecting development-only lint tooling. There is no upstream patched version at this audit. The exception in the plugin's advisory checker is restricted to dev-only picomatch 4.0.7, expires 2026-12-02, and does not exempt any other advisory. The deployed extension's production dependency tree does not contain this package.

### Verify the policy

The Linux x86_64 CI gate installs the YAML parser from hash-pinned binary wheels and runs:

```bash
python3 scripts/test_supply_chain.py
python3 scripts/audit_supply_chain.py
```

The audit covers the root and initialized submodules. It rejects movable action references, retained checkout credentials, privileged PR triggers, build jobs with write tokens, deployment jobs that execute code, npm installs with hooks enabled, and npm artifacts without registry URLs and SHA-512 integrity. The required root security check makes policy regressions visible before merging.

For plugin work, use the isolated Linux checker:

```bash
python3 scripts/check_plugin_isolated.py
```

It requires bubblewrap and Node 24. It copies tracked source into a disposable filesystem with no host home, Git metadata, operator files, credentials, or Docker socket. npm installation and registry verification run with hooks disabled; dependency code then runs without networking. There is no unsafe fallback if sandboxing is unavailable.

Rust build scripts, Dart build hooks, compiler plugins, and explicitly invoked JavaScript can all execute code. Run full ecosystem checks in disposable CI or a separate build account without publishing/cloud credentials. Keep package-publishing authentication out of the development/build profile. Use phishing-resistant MFA for maintainer and publisher accounts, keep recovery methods protected, and revoke obsolete tokens through the provider. Repository changes cannot verify those account controls or revoke copied credentials.

Inspect/apply repository settings using the authenticated gh CLI (no secret values are read):

```bash
python3 scripts/harden_github.py
python3 scripts/harden_github.py --apply --include-site
```

The separate marketing checkout has no npm build or GitHub Actions deployment. Its unused Actions service is disabled, and its EmailJS browser dependency uses an exact release and Subresource Integrity verified against the npm registry archive. Cloudflare deployment credentials and account settings remain provider-managed.


### Resolved dependencies and container builds

The full release gate queries OSV for resolved public Dart, Rust, and Go versions after dependency resolution. Only public package names and versions leave the runner; source and operator files are excluded. npm has its separate registry/signature gate. Lookup failures fail the check instead of reporting a clean result.

This audit updated anyhow to 1.0.103 and rustix to 1.1.6 to resolve RUSTSEC-2026-0190 and RUSTSEC-2026-0486. OSV also reports the informational chrono maintenance notice RUSTSEC-2026-0543. Maintenance notices are printed separately from security vulnerabilities; the existing HLC implementation is not rewritten during this security change. The Cargo lockfile still pins chrono and its checksum, and builds use --locked.

Server builder/runtime images are pinned to official multi-platform SHA-256 manifests. Rust compilation remains sequential before Dart compilation, and Docker uses both Cargo's locked resolution and Dart's enforced lockfile. Dependabot proposes reviewed Docker and Cargo updates; there is no automatic publishing or merging.
