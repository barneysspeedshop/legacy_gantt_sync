#!/bin/bash
set -euo pipefail

# Ensure we are in project root (assuming script is in scripts/)
cd "$(dirname "$0")/.."

echo "----------------------------------------------------------------"
echo "Starting Legacy Gantt Sync - Local Dev Environment"
echo "----------------------------------------------------------------"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
  echo "Error: Docker is not running. Please start Docker."
  exit 1
fi

# Export Environment Variables for Local Dev
export DB_HOST=localhost
export DB_PORT=5432
export DB_USER=dart_user
: "${DB_PASS:?Set DB_PASS before starting the development server}"
export DB_PASS
export DB_NAME=legacy_gantt
export DB_SSL_MODE=disable

export REDIS_HOST=localhost
export REDIS_PORT=6379

: "${JWT_SECRET:?Set JWT_SECRET before starting the development server}"
export JWT_SECRET

if [ -z "${LOCAL_INSPECTOR_TOKEN:-}" ]; then
  echo "Error: LOCAL_INSPECTOR_TOKEN must be set before starting the local inspector."
  exit 1
fi
export LOCAL_INSPECTOR_TOKEN
export LOCAL_INSPECTOR_PORT=${LOCAL_INSPECTOR_PORT:-8787}

: "${SUPERUSER_USERNAME:?Set SUPERUSER_USERNAME}"
: "${SUPERUSER_PASSWORD:?Set SUPERUSER_PASSWORD}"
export SUPERUSER_USERNAME SUPERUSER_PASSWORD

echo "Starting Database (Postgres) and Cache (Redis)..."

# Use the local docker-compose.yml to spin up just db and redis
docker-compose up -d db redis

echo "Waiting for Database to be ready..."
until docker-compose exec -T db pg_isready -U dart_user -d legacy_gantt > /dev/null 2>&1; do
  echo "Waiting for postgres..."
  sleep 2
done
echo "Database is ready!"

echo "----------------------------------------------------------------"
echo "Starting Dart Server..."
echo "----------------------------------------------------------------"

# Run the server and local inspector as separate processes.
dart run bin/server.dart &
SERVER_PID=$!

dart run bin/local_db_inspector.dart &
INSPECTOR_PID=$!

cleanup() {
  kill "$INSPECTOR_PID" "$SERVER_PID" 2>/dev/null || true
  wait "$INSPECTOR_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

while kill -0 "$SERVER_PID" 2>/dev/null && kill -0 "$INSPECTOR_PID" 2>/dev/null; do
  sleep 1
done
