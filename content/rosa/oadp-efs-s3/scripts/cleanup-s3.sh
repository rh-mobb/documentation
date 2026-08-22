#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup-s3.sh --env-file FILE

Deletes the four versioned S3 buckets recorded in dr.env.
All object versions and delete markers are purged before bucket deletion.
EOF
}

ENV_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$ENV_FILE" ] || { echo "--env-file is required" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${APP_BUCKET_PRIMARY:?}"
: "${APP_BUCKET_DR:?}"
: "${OADP_BUCKET_PRIMARY:?}"
: "${OADP_BUCKET_DR:?}"

export AWS_PAGER=""

bucket_exists() {
  aws s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

empty_versioned_bucket() {
  local bucket="$1"
  local versions_file
  local delete_file
  local count

  if ! bucket_exists "$bucket"; then
    echo "Bucket $bucket is already absent."
    return
  fi

  while :; do
    versions_file=$(mktemp)
    delete_file=$(mktemp)

    aws s3api list-object-versions \
      --bucket "$bucket" \
      --output json > "$versions_file"

    jq -c '{
      Objects: (
        [
          (.Versions // [])[],
          (.DeleteMarkers // [])[]
        ]
        | map({Key: .Key, VersionId: .VersionId})
        | .[:1000]
      )
    }' "$versions_file" > "$delete_file"

    count=$(jq '.Objects | length' "$delete_file")
    if [ "$count" = "0" ]; then
      rm -f "$versions_file" "$delete_file"
      break
    fi

    echo "Deleting ${count} object versions/delete markers from ${bucket}."
    jq -c '{Objects: .Objects}' "$delete_file"

    aws s3api delete-objects \
      --bucket "$bucket" \
      --delete "file://$delete_file" >/dev/null

    rm -f "$versions_file" "$delete_file"
  done

  aws s3 rb "s3://$bucket" --force
  echo "Deleted bucket $bucket."
}

for bucket in "$APP_BUCKET_PRIMARY" "$APP_BUCKET_DR" "$OADP_BUCKET_PRIMARY" "$OADP_BUCKET_DR"; do
  empty_versioned_bucket "$bucket"
done
