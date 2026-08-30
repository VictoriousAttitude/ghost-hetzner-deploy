# Ghost-on-Hetzner (zero inbound ports) — Implementation Plan

**Goal:** One command deploys a Ghost blog on a Hetzner cx22 VPS that has NO public inbound
ports; SSH goes over Tailscale SSH, public HTTPS via Tailscale Funnel.

**Architecture:** `deploy.sh` provisions a deny-all-inbound Hetzner Cloud Firewall and a server
whose entire bootstrap is cloud-init (the script can never SSH in over the public IP — there is
no path). cloud-init installs Docker + Tailscale, joins the tailnet with SSH enabled, starts
Ghost + MySQL via compose, and exposes Ghost's port 2368 to the internet with
`tailscale funnel --bg 2368` (public 443, TLS by Tailscale).

**Tech stack:** bash + hcloud CLI 1.67, cloud-init, Docker compose (`ghost` + `mysql:8`),
Tailscale 1.102 (SSH + Funnel).

## Global constraints

- Secrets `HCLOUD_TOKEN`, `TS_AUTHKEY` from env only; never printed, never in tracked files.
- Firewall: zero inbound rules. Nothing may depend on public-IP SSH.
- Server: `cx23` / `ubuntu-24.04` / `fsn1` / name `ghost-blog`. (Spec said cx22; Hetzner retired
  it — `hcloud server-type list` on 2026-08-30 shows cx23 as the smallest x86 type in fsn1.)
- Ghost `url=https://ghost-blog.tail0266d4.ts.net` must be set BEFORE first Ghost boot
  (Ghost bakes absolute URLs into content/redirects).
- Both scripts idempotent; shellcheck-clean (enforced by PostToolUse hook).
- Scope: Tailscale only. No extra features.

## Verified facts (researched 2026-08-30)

- Ghost container listens on 2368; env config uses `__` nesting: `url`, `database__client`,
  `database__connection__{host,user,password,database}` (docs.ghost.org/config, docker-library).
- `tailscale funnel --bg 2368` runs in background, publishes on 443 (CLI 1.102 help; kb/1223).
  Requires `funnel` nodeAttr + HTTPS certs — both enabled tenant-wide (given).
- `tailscale up --ssh --authkey=… --hostname=ghost-blog` (CLI help).
- `hcloud server create --name --type --image --location --firewall --user-data-from-file`
  (hcloud 1.67 help). A firewall with no rules denies all inbound by default.

## Tasks

### Task 1: cloud-init.yaml (template)

Files: `cloud-init.yaml` (template with `${TS_AUTHKEY}`, `${MYSQL_PASSWORD}` — rendered by
deploy.sh via envsubst into an untracked temp file).

Steps:
- [ ] Install Docker via get.docker.com (includes compose plugin) and Tailscale via official
      install script, pinned as documented install methods.
- [ ] Write `/opt/ghost/docker-compose.yml`: `ghost:5` (port 2368, env url + database__*),
      `mysql:8` with healthcheck; Ghost `depends_on: condition: service_healthy`.
- [ ] runcmd order: install docker → install tailscale → `tailscale up --ssh --authkey
      --hostname=ghost-blog` → `docker compose up -d` → `tailscale funnel --bg 2368`.
- [ ] Validate template locally: render with dummy values, `python3 -c yaml.safe_load`.

### Task 2: deploy.sh

Files: `deploy.sh` (`set -Eeuo pipefail`, named steps, echo progress, doc comments).

Steps:
- [ ] Preflight: require `HCLOUD_TOKEN`, `TS_AUTHKEY`, `hcloud`, `envsubst`; verify auth with a
      cheap read call.
- [ ] Firewall `ghost-deny-all`: create only if absent (idempotent), zero rules.
- [ ] Render cloud-init to `mktemp` (0600, trap-deleted); generate MYSQL_PASSWORD once.
- [ ] Server `ghost-blog`: create only if absent, with firewall + user-data.
- [ ] Poll (with timeout): node on tailnet (`tailscale status`), then
      `curl -s -o /dev/null -w %{http_code} https://ghost-blog.tail0266d4.ts.net` → 200.
- [ ] Print Funnel URL + how to SSH.

### Task 3: teardown.sh

Steps:
- [ ] Best effort: `tailscale ssh root@ghost-blog tailscale logout` (removes node from tailnet).
- [ ] `hcloud server delete ghost-blog` if exists; `hcloud firewall delete ghost-deny-all` if
      exists. Idempotent: absent resources are a no-op, not an error.

### Task 4: pre-execution review

- [ ] Dispatch code-reviewer + silent-failure-hunter subagents on all three files with this plan
      as context. Fix real findings. Review gates the paid run.

### Task 5: execute + verify

- [ ] `./deploy.sh` on record. Failure protocol: hypothesis → one change → re-run.
- [ ] Prove acceptance criteria (below), then screenshots (human), then `./teardown.sh`, prove [d].

### Task 6: README + ADR, commit, push

- [ ] README: prerequisites, the ONE command, SSH-after, mermaid diagram, teardown, mini-ADR.
- [ ] Conventional commits, push.

## Acceptance criteria

- **[a]** `curl -I https://ghost-blog.tail0266d4.ts.net` → `HTTP/2 200` + `x-powered-by: Express`
  (Ghost).
- **[b]** `tailscale ssh root@ghost-blog 'docker ps'` from this laptop shows ghost + mysql.
- **[c]** `nmap -Pn <public IPv4>` from this laptop → all scanned TCP ports filtered/closed.
- **[d]** After `./teardown.sh`: `hcloud server list` and `hcloud firewall list` both empty.

## Risks

- cloud-init is fire-and-forget: if it fails mid-way there is no SSH fallback until `tailscale up`
  has run. Mitigation: keep runcmd minimal and ordered so tailscale joins as early as possible
  (debug access via Tailscale SSH even if later steps fail); deploy.sh timeout prints a hint to
  check `hcloud server describe`.
- MySQL takes ~30s to init: healthcheck + service_healthy prevents Ghost crash-looping.
