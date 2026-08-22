#!/usr/bin/env sh

# Source this file from bash or zsh. It defines validation helpers only; it does
# not contact AWS or either cluster until one of the functions is called.

if [ -n "${BASH_VERSION:-}" ]; then
  _validation_helpers_path="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _validation_helpers_path="${(%):-%x}"
else
  _validation_helpers_path="$0"
fi

_validation_helpers_dir=$(CDPATH= cd -- "$(dirname "$_validation_helpers_path")" && pwd)
_validation_repo_root=$(git -C "$_validation_helpers_dir" rev-parse --show-toplevel 2>/dev/null || true)

if [ -z "$_validation_repo_root" ]; then
  _validation_repo_root=$(CDPATH= cd -- "$_validation_helpers_dir/../../../.." && pwd)
fi

stop_here() {
  echo "$1"
  return 1 2>/dev/null || false
}

persist_env() {
  key="$1"
  value="$2"

  [ -n "${DR_ENV:-}" ] || stop_here "DR_ENV is not set"

  tmp_env=$(mktemp)
  touch "$DR_ENV"
  grep -v -E "^export ${key}=" "$DR_ENV" > "$tmp_env" || true
  printf 'export %s=%s\n' "$key" "$value" >> "$tmp_env"
  mv "$tmp_env" "$DR_ENV"
}

require_password() {
  fallback="${_validation_repo_root}/.env.fallback"
  [ -f "$fallback" ] || stop_here "Missing ${fallback}"
  # shellcheck disable=SC1090
  . "$fallback"
  [ -n "${TF_VAR_admin_password:-}" ] || stop_here "TF_VAR_admin_password is not set"
}

login_primary() {
  require_password || return 1
  [ -n "${DR_ENV:-}" ] || stop_here "DR_ENV is not set"
  # shellcheck disable=SC1090
  . "$DR_ENV"

  PRIMARY_API=$(rosa describe cluster -c "$PRIMARY_CLUSTER_NAME" -o json | jq -r '.api.url')
  oc login "$PRIMARY_API" --username admin --password "$TF_VAR_admin_password" || stop_here "Primary oc login failed; stop here."
  CURRENT_API=$(oc whoami --show-server)
  [ "$CURRENT_API" = "$PRIMARY_API" ] || stop_here "Logged in to ${CURRENT_API}, expected ${PRIMARY_API}; stop here."
  oc get nodes >/dev/null || stop_here "Primary node check failed; stop here."
}

login_dr() {
  require_password || return 1
  [ -n "${DR_ENV:-}" ] || stop_here "DR_ENV is not set"
  # shellcheck disable=SC1090
  . "$DR_ENV"

  DR_API=$(rosa describe cluster -c "$DR_CLUSTER_NAME" -o json | jq -r '.api.url')
  oc login "$DR_API" --username admin --password "$TF_VAR_admin_password" || stop_here "DR oc login failed; stop here."
  CURRENT_API=$(oc whoami --show-server)
  [ "$CURRENT_API" = "$DR_API" ] || stop_here "Logged in to ${CURRENT_API}, expected ${DR_API}; stop here."
  oc get nodes >/dev/null || stop_here "DR node check failed; stop here."
}
