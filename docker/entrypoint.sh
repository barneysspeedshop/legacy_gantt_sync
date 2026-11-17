#!/bin/sh

# Helper function to load secret from file into environment variable
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"

    # Check if the _FILE var is set (e.g. POSTGRES_PASSWORD_FILE)
    # and if the file actually exists
    if [ -n "$(eval echo \$$fileVar)" ] && [ -f "$(eval echo \$$fileVar)" ]; then
        val="$(cat "$(eval echo \$$fileVar)")"
        export "$var"="$val"
    elif [ -n "$def" ]; then
        export "$var"="$def"
    fi
}

# Load secrets
# Usage: file_env VAR_NAME [DEFAULT_VALUE]
file_env 'DB_PASS'
file_env 'JWT_SECRET'
# Note: REDIS_PASSWORD usually comes via env var in this setup, 
# but if you used a secret for it, you'd load it here too.

# Execute the CMD from the Dockerfile (which is the dart server)
exec "$@"
