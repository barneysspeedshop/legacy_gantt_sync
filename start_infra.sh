#!/usr/bin/env bash
set -Eeuo pipefail

# This launcher is for local development only. The database volume is mounted
# at /var/lib/postgresql because PostgreSQL 18 uses a major-version-specific
# data directory below that mount. See docs/postgresql-18-migration.md before
# migrating an existing PostgreSQL volume.

DB_PASSWORD=${DB_PASS:-dart_password}

POSTGRES_IMAGE='postgres:18.7@sha256:eb63372c1e05c755f55fa30cbd07aecc443676fc6c0fa90b9002d01537841e1a'
REDIS_IMAGE='redis:8.10.3@sha256:1f88291b4c57bdf249f02eb085a8669889b2d2954e91d4de5118a5da6b78dd53'

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker command not found." >&2
    exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo command not found." >&2
    exit 1
fi

docker_cmd() {
    sudo docker "$@"
}

declare -A EXISTING_STATES=()
MISMATCHES=()

# Preflight both names before starting or creating either service. An existing
# container with a different configured image is never removed or replaced:
# that could destroy a user's old database or silently bypass migration.
for service in redis legacy_db; do
    ids=$(docker_cmd container ls -aq --filter "name=^/${service}$")
    if [[ -n "$ids" ]]; then
        config=$(docker_cmd container inspect \
            --format $'{{.Config.Image}}\t{{.State.Status}}' \
            "$service")
        image=${config%%$'\t'*}
        state=${config#*$'\t'}
        expected_image=$REDIS_IMAGE
        [[ "$service" == legacy_db ]] && expected_image=$POSTGRES_IMAGE
        if [[ "$image" != "$expected_image" ]]; then
            MISMATCHES+=("existing container '$service' uses image '$image', but this launcher requires '$expected_image'")
        else
            EXISTING_STATES["$service"]=$state
        fi
    fi
done

if (( ${#MISMATCHES[@]} > 0 )); then
    printf 'Error: %s\n' "${MISMATCHES[@]}" >&2
    echo 'No containers were changed. Read docs/postgresql-18-migration.md before migrating existing data.' >&2
    exit 1
fi

ensure_service() {
    local service=$1
    local image=$2
    local port=$3
    local volume=$4
    local state=${EXISTING_STATES[$service]:-}

    if [[ -n "$state" ]]; then
        if [[ "$state" == running ]]; then
            echo "$service is already running."
        else
            echo "Starting existing $service container..."
            docker_cmd start "$service"
        fi
        return
    fi

    echo "Creating $service container..."
    if [[ "$service" == legacy_db ]]; then
        docker_cmd run -d \
            --name "$service" \
            --publish "127.0.0.1:${port}:${port}" \
            --volume "$volume" \
            --env 'POSTGRES_USER=dart_user' \
            --env "POSTGRES_PASSWORD=$DB_PASSWORD" \
            --env 'POSTGRES_DB=legacy_gantt' \
            "$image"
    else
        docker_cmd run -d \
            --name "$service" \
            --publish "127.0.0.1:${port}:${port}" \
            --volume "$volume" \
            "$image"
    fi
}

ensure_service redis "$REDIS_IMAGE" 6379 redis_data:/data
ensure_service legacy_db "$POSTGRES_IMAGE" 5432 pgdata:/var/lib/postgresql

echo "Infrastructure started."
