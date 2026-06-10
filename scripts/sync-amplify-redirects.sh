#!/usr/bin/env bash
# Build merged Amplify redirect rules and sync to Amplify Hosting.
# Static rules: customRules.json
# Hugo content aliases: public/experts/_redirects (requires hugo build with disableAliases = true)
set -euo pipefail

STATIC_RULES="${STATIC_RULES:-customRules.json}"
HUGO_REDIRECTS="${HUGO_REDIRECTS:-public/experts/_redirects}"
APP_ID="${AWS_APP_ID:?AWS_APP_ID is required}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

if [[ ! -f "$STATIC_RULES" ]]; then
  echo "Static rules file not found: $STATIC_RULES" >&2
  exit 1
fi

if [[ ! -f "$HUGO_REDIRECTS" ]]; then
  echo "Hugo redirects file not found: $HUGO_REDIRECTS" >&2
  echo "Run: hugo --gc --minify --theme rhds" >&2
  exit 1
fi

MERGED_RULES="$(mktemp)"
trap 'rm -f "$MERGED_RULES"' EXIT

python3 scripts/merge-amplify-redirects.py "$STATIC_RULES" "$HUGO_REDIRECTS" > "$MERGED_RULES"
python3 -m json.tool "$MERGED_RULES" > /dev/null

echo "Updating Amplify custom rules for app ${APP_ID} (${AWS_REGION})..."
aws amplify update-app \
  --region "$AWS_REGION" \
  --app-id "$APP_ID" \
  --custom-rules "file://${MERGED_RULES}" \
  > /dev/null

echo "Amplify custom rules updated."
