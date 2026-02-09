#!/usr/bin/env bash
#
# Export secrets from the hess.pm Kubernetes cluster and generate a .env file
# for bootstrapping the unsereiner.net environment.
#
# Usage: ./export-secrets.sh [output-file]
#   output-file: path to write the .env file (default: .env)
#
# Prerequisites:
#   - kubectl configured with access to the hess.pm cluster
#   - current context should be "hess.pm"
#
set -euo pipefail

OUTPUT="${1:-.env}"
NAMESPACE="argocd"

# Verify we're on the right cluster
CONTEXT=$(kubectl config current-context 2>/dev/null)
if [[ "$CONTEXT" != "hess.pm" ]]; then
  echo "ERROR: Expected kubectl context 'hess.pm', got '$CONTEXT'" >&2
  echo "Switch with: kubectl config use-context hess.pm" >&2
  exit 1
fi

# Helper: extract a base64-decoded value from a secret
get_secret_value() {
  local secret="$1"
  local key="$2"
  local ns="${3:-$NAMESPACE}"
  kubectl get secret "$secret" -n "$ns" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

# Helper: escape a value for safe use inside double quotes in a .env file
escape_value() {
  local val="$1"
  val="${val//\\/\\\\}"   # escape backslashes first
  val="${val//\"/\\\"}"   # escape double quotes
  val="${val//\$/\\\$}"   # escape dollar signs
  val="${val//\`/\\\`}"   # escape backticks
  printf '%s' "$val"
}

echo "Exporting secrets from hess.pm cluster (context: $CONTEXT)..."

TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

{
  cat <<HEADER
# =============================================================================
# unsereiner.net secrets
# Exported from hess.pm Kubernetes cluster on ${TIMESTAMP}
# =============================================================================

# -----------------------------------------------------------------------------
# Akeyless - Secrets management
# -----------------------------------------------------------------------------
HEADER
  printf 'AKEYLESS_ACCESS_ID="%s"\n' "$(escape_value "$(get_secret_value akeyless-secret-creds accessId)")"
  printf 'AKEYLESS_ACCESS_KEY="%s"\n' "$(escape_value "$(get_secret_value akeyless-secret-creds accessTypeParam)")"

  cat <<HEADER

# -----------------------------------------------------------------------------
# Cloudflare - DNS and certificate management
# -----------------------------------------------------------------------------
HEADER
  printf 'CLOUDFLARE_API_KEY="%s"\n' "$(escape_value "$(get_secret_value cloudflare-api-credentials apiKey)")"
  printf 'CLOUDFLARE_EMAIL="%s"\n' "$(escape_value "$(get_secret_value cloudflare-api-credentials email)")"

  cat <<HEADER

# -----------------------------------------------------------------------------
# OAuth2 Proxy - Authentication (Traefik)
# -----------------------------------------------------------------------------
HEADER
  printf 'OAUTH2_PROXY_CLIENT_ID="%s"\n' "$(escape_value "$(get_secret_value oauth2-proxy client-id)")"
  printf 'OAUTH2_PROXY_CLIENT_SECRET="%s"\n' "$(escape_value "$(get_secret_value oauth2-proxy client-secret)")"
  printf 'OAUTH2_PROXY_COOKIE_SECRET="%s"\n' "$(escape_value "$(get_secret_value oauth2-proxy cookie-secret)")"

  cat <<HEADER

# -----------------------------------------------------------------------------
# ArgoCD
# -----------------------------------------------------------------------------
HEADER
  printf 'ARGOCD_ADMIN_PASSWORD="%s"\n' "$(escape_value "$(get_secret_value argocd-initial-admin-secret password)")"
  printf 'ARGOCD_GITHUB_WEBHOOK_SECRET="%s"\n' "$(escape_value "$(kubectl get secret argocd-secret -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.data["webhook.github.secret"] // empty' | base64 -d 2>/dev/null || echo "")")"
} > "$OUTPUT"

echo "Secrets written to $OUTPUT"
echo ""
echo "Secrets exported:"
grep -c '=' "$OUTPUT" | xargs -I{} echo "  {} variables"
echo ""
echo "WARNING: This file contains sensitive credentials. Do not commit to git."
