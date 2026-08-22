#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-s3-replication.sh --env-file FILE

Verifies guide-created S3 buckets have versioning enabled and that a primary
app-bucket marker replicates to the DR app bucket.
EOF
}

ENV_FILE="./dr.env"

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

source "$ENV_FILE"

: "${APP_BUCKET_PRIMARY:?}"
: "${APP_BUCKET_DR:?}"
: "${OADP_BUCKET_PRIMARY:?}"
: "${OADP_BUCKET_DR:?}"
: "${PRIMARY_REGION:?}"
: "${DR_REGION:?}"

export AWS_PAGER=""

for bucket in "$APP_BUCKET_PRIMARY" "$APP_BUCKET_DR" "$OADP_BUCKET_PRIMARY" "$OADP_BUCKET_DR"; do
  status=$(aws s3api get-bucket-versioning --bucket "$bucket" --query 'Status' --output text)
  printf 'bucket/%s versioning=%s\n' "$bucket" "$status"
  [ "$status" = "Enabled" ] || { echo "Versioning is not enabled on ${bucket}." >&2; exit 1; }
done

marker="s3-crr-$(date +%Y%m%d-%H%M%S)"
marker_file=$(mktemp)
trap 'rm -f "$marker_file"' EXIT

printf '%s\n' "$marker" > "$marker_file"
aws s3 cp "$marker_file" "s3://${APP_BUCKET_PRIMARY}/validation/${marker}.txt" --region "$PRIMARY_REGION" >/dev/null

for attempt in $(seq 1 60); do
  if replicated=$(aws s3 cp "s3://${APP_BUCKET_DR}/validation/${marker}.txt" - --region "$DR_REGION" 2>/dev/null); then
    printf 'replicated-marker=%s\n' "$replicated"
    [ "$replicated" = "$marker" ] || { echo "Unexpected replicated marker content." >&2; exit 1; }
    echo "S3 replication validation PASS."
    exit 0
  fi
  printf '[%s] waiting for S3 CRR marker %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$marker"
  sleep 20
done

echo "Timed out waiting for app bucket CRR marker ${marker}." >&2
exit 1
