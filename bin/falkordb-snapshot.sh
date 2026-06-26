#!/usr/bin/env bash
# Trigger FalkorDB BGSAVE and upload the resulting dump.rdb to S3-compatible storage.
# Intended to run via a Fly machine scheduled task or external cron.
#
# Environment variables:
#   REDIS_HOST  (default: localhost)
#   REDIS_PORT  (default: 6379)
#   S3_BUCKET   (required for upload; if unset, only BGSAVE runs)
#   S3_ENDPOINT (optional; for S3-compatible providers like Cloudflare R2)
#   DUMP_PATH   (default: /var/lib/falkordb/data/dump.rdb)

set -euo pipefail

REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
DUMP_PATH="${DUMP_PATH:-/var/lib/falkordb/data/dump.rdb}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

echo "[$(date -u +%FT%TZ)] triggering BGSAVE on ${REDIS_HOST}:${REDIS_PORT}"
PRIOR_LASTSAVE="$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LASTSAVE)"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" BGSAVE

# Poll until LASTSAVE changes, indicating BGSAVE completed.
DEADLINE=$(( $(date +%s) + 600 ))  # 10 minute ceiling
while :; do
  CURRENT="$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LASTSAVE)"
  if [ "$CURRENT" != "$PRIOR_LASTSAVE" ]; then
    echo "[$(date -u +%FT%TZ)] BGSAVE complete (LASTSAVE: ${CURRENT})"
    break
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    echo "[$(date -u +%FT%TZ)] BGSAVE poll timeout; aborting"
    exit 1
  fi
  sleep 5
done

if [ -z "${S3_BUCKET:-}" ]; then
  echo "[$(date -u +%FT%TZ)] S3_BUCKET not set; skipping upload (BGSAVE only)"
  exit 0
fi

DEST="s3://${S3_BUCKET}/falkordb/dump-${TIMESTAMP}.rdb"

S3_FLAGS=()
if [ -n "${S3_ENDPOINT:-}" ]; then
  S3_FLAGS+=("--endpoint-url" "$S3_ENDPOINT")
fi

echo "[$(date -u +%FT%TZ)] uploading ${DUMP_PATH} to ${DEST}"
aws "${S3_FLAGS[@]}" s3 cp "$DUMP_PATH" "$DEST"
echo "[$(date -u +%FT%TZ)] upload complete"
