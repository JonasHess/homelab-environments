#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Create Akeyless secrets for unsereiner.net
#
# Usage:
#   1. Run ./export-secrets.sh to generate .env from the hess.pm cluster
#   2. ./create-akeyless-secrets.sh [path-to-env-file]
#
# The script auto-loads .env from the script's directory by default.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env}"

# --- Check prerequisites -----------------------------------------------------

for cmd in akeyless jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed or not in PATH." >&2
    if [[ "$cmd" == "akeyless" ]]; then
      echo "Install it: https://docs.akeyless.io/docs/cli" >&2
    fi
    exit 1
  fi
done

if [[ -f "$ENV_FILE" ]]; then
  echo "Loading secrets from $ENV_FILE"
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "ERROR: .env file not found at $ENV_FILE" >&2
  echo "Run ./export-secrets.sh first to generate it." >&2
  exit 1
fi

AKEYLESS_PATH="/unsereiner.net"

# --- Required environment variables -----------------------------------------

required_vars=(
  CLOUDFLARE_EMAIL
  CLOUDFLARE_API_KEY
  OAUTH2_PROXY_CLIENT_ID
  OAUTH2_PROXY_CLIENT_SECRET
  OAUTH2_PROXY_COOKIE_SECRET
  ARGOCD_GITHUB_WEBHOOK_SECRET
  AKEYLESS_ACCESS_ID
  AKEYLESS_ACCESS_KEY
  RESTIC_S3_ACCESS_KEY_ID
  RESTIC_S3_SECRET_ACCESS_KEY
  RESTIC_S3_BUCKET
  RESTIC_S3_ENDPOINT
  RESTIC_S3_REGION
  RESTIC_PASSWORD
)

missing=()
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required environment variables:"
  for var in "${missing[@]}"; do
    echo "  - $var"
  done
  echo ""
  echo "Copy .env.example to .env, fill in the values, then: source .env"
  exit 1
fi

# --- Authenticate with Akeyless ----------------------------------------------

echo "Authenticating with Akeyless..."
if ! AUTH_OUTPUT=$(akeyless auth \
  --access-id "$AKEYLESS_ACCESS_ID" \
  --access-type access_key \
  --access-key "$AKEYLESS_ACCESS_KEY" \
  --json 2>&1); then
  echo "ERROR: Akeyless authentication failed:" >&2
  echo "$AUTH_OUTPUT" >&2
  exit 1
fi

AKEYLESS_TOKEN=$(echo "$AUTH_OUTPUT" | jq -r '.token // empty' 2>/dev/null)

if [[ -z "${AKEYLESS_TOKEN:-}" ]]; then
  echo "ERROR: Could not extract token from auth response:" >&2
  echo "$AUTH_OUTPUT" >&2
  exit 1
fi
echo "  -> Authenticated"
echo ""

# --- Helper ------------------------------------------------------------------

create_secret() {
  local path="$1"
  local value="$2"

  echo "Creating secret: $path"
  if akeyless create-secret \
    --name "$path" \
    --value "$value" \
    --token "$AKEYLESS_TOKEN" 2>/dev/null; then
    echo "  -> Created"
  else
    echo "  -> Already exists, updating..."
    akeyless update-secret-val \
      --name "$path" \
      --value "$value" \
      --token "$AKEYLESS_TOKEN"
    echo "  -> Updated"
  fi
}

# --- Create Akeyless secrets ------------------------------------------------

echo "=== Creating Akeyless secrets under ${AKEYLESS_PATH} ==="
echo ""

# Traefik - ACME / Cloudflare
create_secret "${AKEYLESS_PATH}/acme/cloudflare-api-credentials_email" "$CLOUDFLARE_EMAIL"
create_secret "${AKEYLESS_PATH}/acme/cloudflare-api-credentials_apiKey" "$CLOUDFLARE_API_KEY"

# Traefik & ArgoCD - OAuth2-Proxy
create_secret "${AKEYLESS_PATH}/oidc/oauth2-proxy/client_id" "$OAUTH2_PROXY_CLIENT_ID"
create_secret "${AKEYLESS_PATH}/oidc/oauth2-proxy/client_secret" "$OAUTH2_PROXY_CLIENT_SECRET"
create_secret "${AKEYLESS_PATH}/oidc/oauth2-proxy/cookie_secret" "$OAUTH2_PROXY_COOKIE_SECRET"

# ArgoCD - GitHub webhook
create_secret "${AKEYLESS_PATH}/argocd/webhook/github/secret" "$ARGOCD_GITHUB_WEBHOOK_SECRET"

# Restic - S3 backup credentials
create_secret "/restic/S3_ACCESS_KEY_ID" "$RESTIC_S3_ACCESS_KEY_ID"
create_secret "/restic/S3_SECRET_ACCESS_KEY" "$RESTIC_S3_SECRET_ACCESS_KEY"
create_secret "/restic/S3_BUCKET" "$RESTIC_S3_BUCKET"
create_secret "/restic/S3_ENDPOINT" "$RESTIC_S3_ENDPOINT"
create_secret "/restic/S3_REGION" "$RESTIC_S3_REGION"
create_secret "/restic/RESTIC_PASSWORD" "$RESTIC_PASSWORD"

echo ""
echo "=== Done ==="
