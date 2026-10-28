# n8n Auto-Updater

A small bash script that automatically checks for new [n8n](https://n8n.io) releases, updates your self-hosted Docker instance, and sends Telegram notifications on success or failure.

## What it does

1. Checks the latest n8n release on GitHub.
2. Compares it to the version currently running in your `n8n` Docker container.
3. If a new version is available:
   - Sends a Telegram notification that an update is starting.
   - Pulls the new image and restarts the container via `docker compose`.
   - Waits for n8n to become healthy again.
   - Removes old n8n images to free disk space.
   - Sends a Telegram notification on success or failure.
4. If already up to date, removes any leftover old n8n images and sends a short confirmation message (or you can disable that notification if you'd rather stay quiet).

## Requirements

- A self-hosted n8n instance running via `docker compose`, in a container named `n8n` (configurable).
- `docker`, `curl`, `grep`, `cut`, `sed` available on the host.
- A Telegram bot token and chat ID for notifications ([BotFather](https://t.me/BotFather) to create a bot).

## Setup

1. Clone this repo onto your server:
   ```bash
   git clone https://github.com/viktormikeska/n8n-auto-updater.git
   cd n8n-auto-updater
   ```

2. Copy the example environment file and fill in your values:
   ```bash
   cp .env.example .env
   ```

   | Variable              | Description                                             | Default                  |
   |-----------------------|----------------------------------------------------------|---------------------------|
   | `TELEGRAM_BOT_TOKEN`  | Token for your Telegram bot                              | *(required)*              |
   | `TELEGRAM_CHAT_ID`    | Chat ID to send notifications to                          | *(required)*              |
   | `N8N_COMPOSE_DIR`     | Directory containing your `docker-compose.yml`            | `/root/automation`        |
   | `N8N_URL`             | Base URL used to check n8n's health endpoint              | `https://localhost`       |
   | `N8N_CONTAINER_NAME`  | Name of the running n8n Docker container                  | `n8n`                     |
   | `N8N_IMAGE_CLEANUP`   | Remove old n8n images after each run (`true`/`false`)     | `true`                    |

3. Make the script executable:
   ```bash
   chmod +x n8n_update.sh
   ```

4. Run it manually to test:
   ```bash
   ./n8n_update.sh
   ```

## Scheduling with cron

Run it daily (or on whatever cadence you prefer) with cron:

```cron
0 4 * * * /path/to/n8n-auto-updater/n8n_update.sh >> /var/log/n8n-update.log 2>&1
```

## Notes

- The script does not use `set -e`; it checks the exit status of each critical command (GitHub API call, `docker exec`, `docker compose pull/up`) explicitly and sends a Telegram alert before exiting on failure.
- Image cleanup only removes images from the same repository as the running n8n container (e.g. `docker.n8n.io/n8nio/n8n`), never the image currently in use, and never images of other services. It is skipped when an update fails, so the previous image is still available for a manual rollback. Images still used by another container are left in place with a warning.
- `.env` is gitignored — never commit real credentials.
