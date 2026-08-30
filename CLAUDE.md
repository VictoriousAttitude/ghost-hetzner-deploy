# ghost-hetzner-deploy

One-click Ghost blog on a Hetzner VPS with ZERO public inbound ports. SSH and public HTTPS both go
through Tailscale (SSH over tailnet, blog published via Tailscale Funnel).

## Hard rules

- **Secrets**: `HCLOUD_TOKEN` and `TS_AUTHKEY` live in the environment only. Never echo, print,
  or write them to any tracked file or command output. Scripts reference env vars; `.env` is
  gitignored.
- **Zero inbound**: the Hetzner Cloud Firewall has no inbound rules. Bootstrap is 100% cloud-init;
  nothing may assume SSH over the public IP, ever.
- **Idempotent scripts**: `deploy.sh` and `teardown.sh` must be safe to re-run.
- **Shellcheck-clean**: a PostToolUse hook (`.claude/settings.json`) runs `shellcheck -x` and
  `bash -n` on every edited `*.sh`. Fix findings immediately.
- **Scope**: one tunnel provider (Tailscale). No TLS-termination extras, no multi-provider
  abstraction.

## Fixed parameters

- Server: `cx23` (cx22 retired by Hetzner), `ubuntu-24.04`, `fsn1`, name `ghost-blog`
- Tailnet: `tail0266d4.ts.net`; Funnel + HTTPS certs enabled tenant-wide; auth key is reusable
- Ghost URL (set before first boot): `https://ghost-blog.tail0266d4.ts.net`
- Stack: docker compose, `ghost` + `mysql:8` at `/opt/ghost/docker-compose.yml`

## Process

Hypothesis before every fix; one change between runs; show real output before claiming success.
Code review (code-reviewer + silent-failure-hunter) precedes execution — the run costs money.
