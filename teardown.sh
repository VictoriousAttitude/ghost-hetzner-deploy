#!/usr/bin/env bash
# =============================================================================
# teardown.sh — remove everything deploy.sh created. Idempotent: resources
# that are already gone are a no-op, not an error.
#
#   1. best effort: log the node out of the tailnet (via Tailscale SSH — the
#      only way in). Failure here must not block deletion of paid resources.
#   2. delete the server
#   3. delete the firewall
# =============================================================================
set -Eeuo pipefail

readonly SERVER_NAME="ghost-blog"
readonly FIREWALL_NAME="ghost-deny-all"

step() { echo; echo "==> $*"; }

step "[1/3] preflight"
: "${HCLOUD_TOKEN:?HCLOUD_TOKEN must be set in the environment}"
for cmd in hcloud tailscale timeout; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done

step "[2/3] tailnet logout on '${SERVER_NAME}' (best effort)"
# 'tailscale logout' on the node deletes it from the tailnet and invalidates
# its node key, so no stale machine entry lingers in the admin console.
# The logout tears down the SSH session carrying it, so the ssh exit code is
# meaningless — success is judged by the node disappearing from the tailnet.
if tailscale status | grep -qw "$SERVER_NAME"; then
  timeout 30 tailscale ssh "root@${SERVER_NAME}" tailscale logout || true
  logged_out=false
  for _ in 1 2 3 4 5; do
    sleep 3
    tailscale status | grep -qw "$SERVER_NAME" || { logged_out=true; break; }
  done
  if $logged_out; then
    echo "node logged out of tailnet"
  else
    echo "WARN: node still on the tailnet (it may be down); remove it in the" >&2
    echo "Tailscale admin console if a stale entry remains." >&2
  fi
else
  echo "node not on the tailnet — skipping"
fi

step "[3/3] delete Hetzner resources"
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  hcloud server delete "$SERVER_NAME"
else
  echo "server '${SERVER_NAME}' already gone"
fi
if hcloud firewall describe "$FIREWALL_NAME" >/dev/null 2>&1; then
  hcloud firewall delete "$FIREWALL_NAME"
else
  echo "firewall '${FIREWALL_NAME}' already gone"
fi

echo
echo "Teardown complete. Verify with: hcloud server list && hcloud firewall list"
