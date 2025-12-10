#!/bin/bash

# valid check for docker command
if ! command -v docker &> /dev/null; then
    echo "Error: docker command not found."
    exit 1
fi

echo "Starting Redis..."
if [ "$(sudo docker ps -aq -f name=redis)" ]; then
    if [ "$(sudo docker ps -aq -f status=exited -f name=redis)" ]; then
        # cleanup if exited? or just start? Let's rm and run new to ensure config matches
        sudo docker rm redis
        sudo docker run -d --name redis -p 6379:6379 redis:7
    else
        echo "Redis is already running."
    fi
else
    sudo docker run -d --name redis -p 6379:6379 redis:7
fi

echo "Starting Postgres..."
if [ "$(sudo docker ps -aq -f name=legacy_db)" ]; then
    if [ "$(sudo docker ps -aq -f status=exited -f name=legacy_db)" ]; then
         # Don't rm database container blindly to preserve non-volume data if they didn't use volumes before?
         # But the new command uses volume.
         # Let's just start it if it exists.
         sudo docker start legacy_db
    else
         echo "Postgres is already running."
    fi
else
    sudo docker run -d --name legacy_db \
      -e POSTGRES_USER=dart_user \
      -e POSTGRES_PASSWORD=dart_password \
      -e POSTGRES_DB=legacy_gantt \
      -p 5432:5432 \
      -v pgdata:/var/lib/postgresql/data \
      postgres:15
fi

echo "Infrastructure started."
