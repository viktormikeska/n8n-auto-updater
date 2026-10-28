#!/bin/bash
set -uo pipefail

# n8n Auto-Update Script
# Automatically checks for new n8n versions and updates your self-hosted instance
# Sends Telegram notifications on success or failure
# https://github.com/viktormikeska/n8n-auto-updater

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load environment variables
if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
fi

# Configuration
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
COMPOSE_DIR="${N8N_COMPOSE_DIR:-/root/automation}"
N8N_URL="${N8N_URL:-https://localhost}"
CONTAINER_NAME="${N8N_CONTAINER_NAME:-n8n}"
IMAGE_CLEANUP="${N8N_IMAGE_CLEANUP:-true}"
MAX_RETRIES=18
RETRY_INTERVAL=10

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set (via .env or environment)." >&2
    exit 1
fi

# Send a Telegram message; logs a warning if delivery fails but never aborts the script
send_telegram() {
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=$1" \
        -d "parse_mode=Markdown")
    if [ "$response" != "200" ]; then
        echo "WARNING: Telegram notification failed (HTTP $response)" >&2
    fi
}

# Wait until n8n is fully up and responding
wait_for_n8n() {
    echo "Waiting for n8n to be ready..."
    until curl -s -o /dev/null -w "%{http_code}" "${N8N_URL}/healthz" | grep -q "200"; do
        sleep 5
    done
    echo "n8n is ready."
}

# Remove old n8n images that are not used by the running container.
# Only touches images from the same repository as the container's image; never aborts the script.
# Sets REMOVED_IMAGES to the number of images removed.
REMOVED_IMAGES=0
cleanup_old_images() {
    REMOVED_IMAGES=0
    if [ "$IMAGE_CLEANUP" != "true" ]; then
        echo "Image cleanup disabled (N8N_IMAGE_CLEANUP=$IMAGE_CLEANUP)."
        return
    fi

    local image_ref current_id repo id
    image_ref=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
    current_id=$(docker inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null)
    if [ -z "$image_ref" ] || [ -z "$current_id" ]; then
        echo "WARNING: Could not inspect the '$CONTAINER_NAME' container, skipping image cleanup." >&2
        return
    fi

    # Strip digest and tag (keeping a registry port like host:5000/n8n intact)
    repo="${image_ref%@*}"
    if [[ "${repo##*/}" == *:* ]]; then
        repo="${repo%:*}"
    fi

    echo "Removing old images of $repo..."
    for id in $(docker images --no-trunc --format '{{.ID}}' "$repo" | sort -u); do
        [ "$id" = "$current_id" ] && continue
        if docker rmi "$id" >/dev/null 2>&1; then
            REMOVED_IMAGES=$((REMOVED_IMAGES + 1))
            echo "Removed image $id"
        else
            echo "WARNING: Could not remove image $id (it may be used by another container)" >&2
        fi
    done
    echo "Removed $REMOVED_IMAGES old image(s)."
}

# Telegram message line about cleaned-up images (empty if nothing was removed)
cleanup_note() {
    if [ "$REMOVED_IMAGES" -gt 0 ]; then
        printf '\n\n🧹 Removed %s old n8n image(s).' "$REMOVED_IMAGES"
    fi
}

# Get latest n8n version from GitHub
LATEST_VERSION=$(curl -sf https://api.github.com/repos/n8n-io/n8n/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/n8n@//')
if [ -z "$LATEST_VERSION" ]; then
    echo "ERROR: Could not determine latest n8n version from GitHub API." >&2
    send_telegram "⚠️ *n8n update check failed!*

Could not fetch the latest version from GitHub. Will retry on the next scheduled run."
    exit 1
fi

# Get current installed version
CURRENT_VERSION=$(docker exec "$CONTAINER_NAME" n8n --version 2>/dev/null)
if [ -z "$CURRENT_VERSION" ]; then
    echo "ERROR: Could not determine current n8n version (is the '$CONTAINER_NAME' container running?)." >&2
    send_telegram "⚠️ *n8n update check failed!*

Could not read the current version from the '${CONTAINER_NAME}' container. Please check that it is running."
    exit 1
fi

echo "Current version: $CURRENT_VERSION"
echo "Latest version:  $LATEST_VERSION"

# Check if update is needed
if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo "n8n is already up to date."
    cleanup_old_images
    send_telegram "✅ *n8n is up to date!*

Current version: _${CURRENT_VERSION}_

No action required.$(cleanup_note)"
    exit 0
fi

# Notify update is starting
send_telegram "🆕 *New n8n version available!*

Current version: _${CURRENT_VERSION}_
Latest version: _${LATEST_VERSION}_

Update starting now..."

# Pull latest image and restart
echo "Pulling latest n8n image..."
if ! docker compose -f "$COMPOSE_DIR/docker-compose.yml" pull n8n; then
    echo "ERROR: docker compose pull failed" >&2
    send_telegram "❌ *n8n update failed!*

Failed to pull the latest n8n image.

Please check your server."
    exit 1
fi

echo "Restarting n8n..."
if ! docker compose -f "$COMPOSE_DIR/docker-compose.yml" up -d n8n; then
    echo "ERROR: docker compose up failed" >&2
    send_telegram "❌ *n8n update failed!*

Failed to restart n8n after pulling the new image.

Please check your server."
    exit 1
fi

# Verify update with retries
RETRIES=0
while [ "$RETRIES" -lt "$MAX_RETRIES" ]; do
    sleep "$RETRY_INTERVAL"
    NEW_VERSION=$(docker exec "$CONTAINER_NAME" n8n --version 2>/dev/null)

    if [ "$NEW_VERSION" = "$LATEST_VERSION" ]; then
        echo "Update successful: $NEW_VERSION"
        wait_for_n8n
        cleanup_old_images
        send_telegram "✅ *n8n updated successfully!*

New version: _${NEW_VERSION}_

n8n is now up to date.$(cleanup_note)"
        exit 0
    fi

    RETRIES=$((RETRIES + 1))
    echo "Attempt $RETRIES/$MAX_RETRIES - current version: $NEW_VERSION"
done

# Update failed
echo "Update failed after $MAX_RETRIES attempts"
send_telegram "❌ *n8n update failed!*

Something went wrong during the update process.

Please check your server."
exit 1