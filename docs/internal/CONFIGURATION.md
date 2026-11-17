# Server Configuration

The Gantt Sync Server is configured via environment variables.

## Core Configuration

| Variable | Description | Default | Required |
| :--- | :--- | :--- | :--- |
| **`LEGACY_GANTT_SYNC_PORT`** | The HTTP port the server listens on. | `8080` | No |
| **`JWT_SECRET`** | Secret key for signing JSON Web Tokens. **Must be kept secure.** | - | **Yes** |
| **`LOCAL_INSPECTOR_TOKEN`** | Required token for the loopback-only local database inspector. | - | Local development only |
| **`LOCAL_INSPECTOR_PORT`** | Port for the loopback-only local database inspector. | `8787` | Local development only |

## Database Connection (PostgreSQL)

| Variable | Description | Default | Required |
| :--- | :--- | :--- | :--- |
| **`DB_HOST`** | Hostname of the PostgreSQL database. | `localhost` | No |
| **`DB_PORT`** | Port of the PostgreSQL database. | `5432` | No |
| **`DB_NAME`** | Name of the database to connect to. | `legacy_gantt` | No |
| **`DB_USER`** | Database username. | - | **Yes** |
| **`DB_PASS`** | Database password. | - | **Yes** |
| **`DB_SSL_MODE`** | SSL mode (`disable`, `require`). | `require` | No |

## Cache / PubSub (Redis)

| Variable | Description | Default | Required |
| :--- | :--- | :--- | :--- |
| **`REDIS_HOST`** | Hostname of the Redis instance. | `localhost` | No |
| **`REDIS_PASSWORD`** | Redis authentication password; required by the Swarm manifest. | - | Swarm only |
| **`REDIS_PORT`** | Port of the Redis instance. | `6379` | No |

## Superuser Seeding

These variables are used to create the initial "System" superuser on first run.

| Variable | Description |
| :--- | :--- |
| **`SUPERUSER_USERNAME`** | Username for the initial admin (e.g. `admin`). |
| **`SUPERUSER_PASSWORD`** | Password for the initial admin. |

## Docker Secrets support

The Docker entrypoint loads `DB_PASS_FILE` and `JWT_SECRET_FILE` from mounted secret files. Direct Dart execution requires `DB_PASS` and `JWT_SECRET` values in the environment. The Swarm manifest mounts database and JWT secrets and requires a unique `REDIS_PASSWORD` in the deployment environment.

Compose requires explicit `DB_PASS` and `JWT_SECRET` values. The development script also requires `SUPERUSER_USERNAME`, `SUPERUSER_PASSWORD`, and `LOCAL_INSPECTOR_TOKEN`; it does not supply shared secret defaults.
