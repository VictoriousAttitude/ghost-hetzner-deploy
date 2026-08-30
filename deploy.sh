#!/usr/bin/env bash
# =============================================================================
# deploy.sh — one-click Ghost blog on Hetzner with ZERO public inbound ports.
#
# What it does:
#   1. preflight   verify env vars, CLIs, and hcloud auth
#   2. firewall    deny-all Hetzner Cloud Firewall (a firewall with no rules
#                  drops all inbound; outbound stays open)
#   3. server      cx22/ubuntu-24.04/fsn1, bootstrapped entirely by cloud-init
#                  (there is no SSH path over the public IP — by design)
#   4. wait        poll until the node joins the tailnet, then until Ghost
#                  answers 200 on the public Funnel URL
#   5. done        print the URL and how to SSH (over Tailscale)
#
# Idempotent: safe to re-run; existing firewall/server are left untouched.
# Secrets: HCLOUD_TOKEN and TS_AUTHKEY are read from the environment and are
# never echoed; the rendered cloud-init (which embeds TS_AUTHKEY) goes to a
# 0600 temp file that is deleted on exit.
# =============================================================================
set -Eeuo pipefail

readonly SERVER_NAME="ghost-blog"
readonly FIREWALL_NAME="ghost-deny-all"
# cx22 was retired by Hetzner; cx23 is the current smallest x86 type in fsn1.
readonly SERVER_TYPE="cx23"
readonly IMAGE="ubuntu-24.04"
readonly LOCATION="fsn1"
readonly FUNNEL_URL="https://ghost-blog.tail0266d4.ts.net"
readonly TAILNET_WAIT_SECS=420   # cloud-init: apt update + tailscale install
readonly GHOST_WAIT_SECS=600     # docker + image pulls + mysql init on a cx22

step() { echo; echo "==> $*"; }

# True if a tailnet peer named $SERVER_NAME exists; with --online-only, it
# must also be currently connected. JSON output is the stable interface —
# grep-ing the human-readable `tailscale status` would also match stale
# offline nodes and mislead the wait loop.
tailnet_node() {
  tailscale status --json | python3 -c '
import json, sys
online_only = "--online-only" in sys.argv
st = json.load(sys.stdin)
peers = (st.get("Peer") or {}).values()
found = any(p.get("HostName") == "'"$SERVER_NAME"'" and (p.get("Online") or not online_only)
            for p in peers)
sys.exit(0 if found else 1)' "${1:-}"
}

# --- 1. preflight ------------------------------------------------------------
step "[1/5] preflight: env vars, CLIs, hcloud auth, local tailscale"
: "${HCLOUD_TOKEN:?HCLOUD_TOKEN must be set in the environment}"
: "${TS_AUTHKEY:?TS_AUTHKEY must be set in the environment}"
# envsubst only sees *exported* variables — without this, a plain shell var
# would render an EMPTY authkey and produce a permanently unreachable server.
export TS_AUTHKEY
for cmd in hcloud envsubst curl tailscale openssl python3; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done
# Cheap read call proves the token is valid before we create anything.
hcloud server list -o noheader >/dev/null
# This machine must be on the tailnet, or the wait loop below can never
# succeed — fail now, before any money is spent.
tailscale status >/dev/null 2>&1 \
  || { echo "ERROR: local tailscale is not running/logged in" >&2; exit 1; }
echo "preflight OK"

# --- 2. firewall -------------------------------------------------------------
step "[2/5] firewall '${FIREWALL_NAME}' (deny-all: zero inbound rules)"
if hcloud firewall describe "$FIREWALL_NAME" >/dev/null 2>&1; then
  echo "firewall already exists — skipping"
else
  hcloud firewall create --name "$FIREWALL_NAME"
fi

# --- 3. server ---------------------------------------------------------------
step "[3/5] server '${SERVER_NAME}' (${SERVER_TYPE}, ${IMAGE}, ${LOCATION})"
if hcloud server describe "$SERVER_NAME" >/dev/null 2>&1; then
  # NOTE: cloud-init only runs on FIRST boot. Re-running this script does not
  # repair a server whose bootstrap failed — that needs ./teardown.sh first.
  echo "server already exists — skipping creation (cloud-init will NOT re-run;"
  echo "if the first boot failed, run ./teardown.sh and deploy again)"
else
  # A leftover tailnet node with our name would make the new server join as
  # 'ghost-blog-1', breaking MagicDNS, the Funnel URL, and Ghost's baked-in
  # url. Refuse to create the server while one exists.
  if tailnet_node; then
    echo "ERROR: a node named '${SERVER_NAME}' already exists on the tailnet" >&2
    echo "(stale from an earlier run?). Remove it in the Tailscale admin" >&2
    echo "console, then re-run." >&2
    exit 1
  fi

  # Render the cloud-init template. envsubst is restricted to exactly the two
  # template variables so '$' elsewhere (retry-loop vars etc.) survives
  # literally. MYSQL_PASSWORD is generated fresh per deploy; it only ever
  # lives on the server and in this transient temp file.
  MYSQL_PASSWORD="$(openssl rand -hex 16)"
  export MYSQL_PASSWORD
  user_data="$(mktemp)"
  trap 'rm -f "$user_data"' EXIT
  chmod 600 "$user_data"
  # shellcheck disable=SC2016  # envsubst takes literal ${VAR} names — no shell expansion wanted
  envsubst '${TS_AUTHKEY} ${MYSQL_PASSWORD}' <cloud-init.yaml >"$user_data"
  # Belt and braces: an empty authkey in the rendered file means a server we
  # can never reach. Check the file without ever printing its contents.
  grep -qE -- '--authkey=[^[:space:]]+' "$user_data" \
    || { echo "ERROR: rendered user-data has an empty --authkey" >&2; exit 1; }

  hcloud server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --image "$IMAGE" \
    --location "$LOCATION" \
    --firewall "$FIREWALL_NAME" \
    --user-data-from-file "$user_data"
fi

# --- 4. wait -----------------------------------------------------------------
step "[4a/5] waiting for '${SERVER_NAME}' to join the tailnet (max ${TAILNET_WAIT_SECS}s)"
deadline=$((SECONDS + TAILNET_WAIT_SECS))
until tailnet_node --online-only; do
  if ((SECONDS >= deadline)); then
    echo "ERROR: node did not appear on the tailnet in time." >&2
    echo "Debug: 'hcloud server describe ${SERVER_NAME}' — the server console" >&2
    echo "in the Hetzner UI shows cloud-init output." >&2
    exit 1
  fi
  printf '.'
  sleep 5
done
echo " on the tailnet"

step "[4b/5] waiting for Ghost to answer at ${FUNNEL_URL} (max ${GHOST_WAIT_SECS}s)"
deadline=$((SECONDS + GHOST_WAIT_SECS))
until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$FUNNEL_URL" || true)" == "200" ]]; do
  if ((SECONDS >= deadline)); then
    echo "ERROR: Ghost did not answer 200 in time." >&2
    echo "Debug over Tailscale SSH: tailscale ssh root@${SERVER_NAME} 'cloud-init status --long; docker ps -a'" >&2
    exit 1
  fi
  printf '.'
  sleep 10
done
echo " Ghost is up"

# --- 5. done -----------------------------------------------------------------
step "[5/5] deployed"
echo "Blog:  ${FUNNEL_URL}"
echo "Admin: ${FUNNEL_URL}/ghost"
echo "SSH:   tailscale ssh root@${SERVER_NAME}"
echo "Public IPv4 (all inbound blocked): $(hcloud server ip "$SERVER_NAME")"
