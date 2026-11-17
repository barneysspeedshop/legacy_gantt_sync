#!/bin/bash
set -e

# Generate a unique tag based on timestamp
TAG="debug-$(date +%s)"
IMAGE_NAME="legacy_gantt_server:$TAG"

# 1. Stop the stack to free up RAM (Critical for 1GB instance)
echo "Stopping Stack to free RAM..."
sudo -E docker stack rm legacy_gantt || true

# 2. Safety Check for Secrets
echo "Verifying secrets folder..."
if [ ! -d "secrets" ] || [ -z "$(ls -A secrets)" ]; then
  echo "ERROR: 'secrets' directory is missing or empty!"
  echo "Please copy your production secrets before deploying."
  exit 1
fi

echo "Waiting 5s for shutdown..."
sleep 5

# Ensure nginx_conf is completely up-to-date with local file
echo "Verifying nginx_conf..."
if sudo docker config inspect nginx_conf >/dev/null 2>&1; then
  RETRY=0
  # Keep trying to remove until the swarm stack fully releases the config
  until sudo docker config rm nginx_conf >/dev/null 2>&1 || [ $RETRY -eq 5 ]; do
    echo "Waiting for stack to detach from old config..."
    sleep 2
    RETRY=$((RETRY+1))
  done
fi

echo "Creating fresh nginx_conf from ./nginx/nginx.conf..."
sudo docker config create nginx_conf ./nginx/nginx.conf

echo "Building Server Image: $IMAGE_NAME..."
# Removed --no-cache to enable faster builds when code hasn't changed.
sudo docker build -t $IMAGE_NAME .

# 3. Redeploy the stack
echo "Deploying Stack with new image..."
# We must edit the docker-swarm.yml on the fly or just set the image in the command? 
# docker stack deploy uses the yaml. 
# We can export the image name as an env var and substitute it if the yaml supports it, OR
# We can just update the service after deploy, but that might fail if the base image in yaml (latest) isn't what we want.
# BETTER APPROACH:
# Use 'envsubst' if available, or just update the service immediately after deploy.
# OR simpler: Tag the built image as 'latest' as well, so deploy picks it up initially, then update to specific tag.

sudo docker tag $IMAGE_NAME legacy_gantt_server:latest

# Deploy uses 'legacy_gantt_server:latest' from yaml
# Use sudo -E to preserve exported environment variables from the user's shell
sudo -E docker stack deploy -c docker-swarm.yml legacy_gantt

# Force update to the specific timestamped tag to be sure (and for traceability)
# But wait, the service initially starts with 'latest'.
# 'latest' now points to our new build. So it should be fine.
# But to be 100% sure Swarm picks up the change if 'latest' digest didn't change enough (unlikely with --no-cache):
# Let's force update to the specific tag.
echo "Updating service to specific tag $TAG..."
sudo -E docker service update --image $IMAGE_NAME --force legacy_gantt_server

echo "Done. Stack redeployed."
echo "You can check logs with: sudo docker service logs -f legacy_gantt_server"
