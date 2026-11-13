<div align="center">

# Snell One-Click Script & Docker Image

[![Stars](https://img.shields.io/github/stars/helloktity/snell?style=flat-square&logo=github&color=blue)](https://github.com/helloktity/snell/stargazers)
[![Forks](https://img.shields.io/github/forks/helloktity/snell?style=flat-square&logo=github&color=blue)](https://github.com/helloktity/snell/network/members)
[![Pull Requests](https://img.shields.io/github/issues-pr/helloktity/snell?style=flat-square&logo=github&color=blue)](https://github.com/helloktity/snell/pulls)
[![License](https://img.shields.io/github/license/helloktity/snell?style=flat-square&color=blue)](LICENSE)

Install and manage Snell v4 / v5 / v6 with one command — with ShadowTLS v3,
multi-user support and BBR, plus a **built-in subscription service** (Sub-Store
can subscribe this host with `source=remote`).

[English](README.en.md) ｜ [中文](README.md) ｜ [Docs (upstream wiki)](https://github.com/jinqians/snell/wiki)

> This repo is a fork of [jinqians/snell](https://github.com/jinqians/snell): same install
> and management logic, plus the subscription service, with all built-in URLs pointing here
> instead of upstream.

</div>

---

## One-click script

Detects the system (Debian / Ubuntu / CentOS / RHEL / Alpine); run the file for your system:

| System | Command |
|--------|---------|
| Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux | `bash <(curl -fsSL https://raw.githubusercontent.com/helloktity/snell/main/snell.sh)` |
| Alpine 3.18 and older (native) | `sh -c "$(curl -fsSL https://raw.githubusercontent.com/helloktity/snell/main/snell-alpine.sh)"` |
| Alpine (in Docker; use this from 3.19 on) | `sh -c "$(curl -fsSL https://raw.githubusercontent.com/helloktity/snell/main/scripts/snell-docker.sh)"` |
| All-in-one menu (Snell / SS-2022 / ShadowTLS) | `bash <(curl -fsSL https://raw.githubusercontent.com/helloktity/snell/main/scripts/menu.sh)` |

Afterwards, `snell` opens the menu: the config, changing the port / PSK / DNS, more users, versions (v4 / v5 / v6 side by side), ShadowTLS, BBR, rule-based routing, **subscription**.

The `snell` command fetches the latest script from this repo on every run, so a push is enough — no reinstall.

---

## Subscription (new in this fork)

The script ships a small subscription service: it publishes the local Snell users
(ShadowTLS included) as a subscription, so Sub-Store can subscribe this host with
`source=remote`, and Mihomo / Surge can import it directly.

Enabled automatically on install; manage it from menu item 14 or from the CLI:

| Purpose | URL (`<base>` = `http://127.0.0.1:13357/<token>`) |
|---|---|
| Sub-Store remote source / Clash fragment (default) | `<base>/sub?target=clash` |
| Full Clash config (import into Verge / Mihomo) | `<base>/sub?target=clash-full` |
| Surge (v6 and ShadowTLS included) | `<base>/sub?target=surge` |
| base64 / JSON / probe | `<base>/sub?target=base64`, `<base>/sub?target=json`, `<base>/health` |

Notes:

- **The Clash targets only emit what Mihomo can run** (snell `version` 4 / 5). v6 and
  ShadowTLS nodes are skipped and listed in a comment at the top of the response — emitting
  them would make the whole profile invalid. The Surge targets carry everything.
- Every request re-reads `/etc/snell/users/*.conf` and the ShadowTLS units, so adding a
  user, rotating a PSK or switching versions shows up immediately, with no restart.
- Config lives in `/etc/snell/.subscription` (600), the 40-char token is part of the path.
  The link is a credential: `snell sub token` rotates it.
- Listens on `127.0.0.1` only by default (enough for Sub-Store on the same host).
  For external access run `snell sub public`: it auto-configures an nginx reverse proxy on
  port 443 reusing the machine's existing certificate and only emits HTTPS links — plain HTTP
  is not offered. Want the snippet instead? `snell sub nginx-hint`.
- Shares a single `/etc/nginx/conf.d/50-subscription.conf` vhost with Mieru-Plus; each script
  drops its own location snippet under `/etc/nginx/snippets/subscription/`.
- Pure python3 standard library, no pip. Without python3 only the subscription is skipped.

```bash
snell sub                # show the links
snell sub on | off       # enable / disable
snell sub check          # request every target once against the local endpoint
snell sub store          # what to put into Sub-Store
snell sub nginx          # reverse-proxy snippet
snell sub token          # rotate the token
```

In Sub-Store add a source of type `remote` with `<base>/sub?target=clash`.
Do **not** also fill in its content: a remote source that still carries old content
makes Sub-Store prefer the old PSKs.

---

## Docker

Image [`jinqians/snell-server`](https://hub.docker.com/r/jinqians/snell-server) is maintained
upstream (amd64 / arm64 / armv7; no armv7 for v6). The container runs as `nobody`, so make its config directory first:

```bash
mkdir -p ./snell-config && chown -R 65534:65533 ./snell-config
docker run -d --name snell-server --restart unless-stopped \
  -p 6160:6160/tcp -p 6160:6160/udp \
  -e SNELL_VER=v5 -e SNELL_PORT=6160 \
  -v ./snell-config:/etc/snell \
  jinqians/snell-server:v5
```

docker compose (`compose.yml`):

```yaml
services:
  snell:
    image: jinqians/snell-server:v5
    container_name: snell-server
    restart: unless-stopped
    ports:
      - "6160:6160/tcp"
      - "6160:6160/udp"
    environment:
      - SNELL_VER=v5
      - SNELL_PORT=6160
    volumes:
      - ./snell-config:/etc/snell
```

For Snell v6: the `:v6` image, `SNELL_VER=v6`, and `SNELL_MODE` for the transport mode (clients must match) → [Deploying Snell v6](https://github.com/jinqians/snell/wiki/Docker#c-deploying-snell-v6).
ShadowTLS, switching versions, every environment variable → [Docker](https://github.com/jinqians/snell/wiki/Docker)

> Publishing your own image: `IMAGE_NAME` in `.github/workflows/docker-publish.yml` uses
> `github.repository_owner`, so a fork builds `<your-user>/snell-server` — add Docker Hub
> credentials to push it.

---

## Getting the client config

```bash
snell                          # script install: menu → "3. Show config" (also prints the subscription links)
snell sub                      # subscription links only
docker logs snell-server       # Docker: printed on first start, also in ./snell-config/client-config.txt
```

It is Surge's format, ready to paste:

```text
HK = snell, 1.2.3.4, 6160, psk = your_psk, version = 5, reuse = true, tfo = true
```

---

## ShadowTLS (optional)

A TLS disguise around Snell; only the ShadowTLS port is exposed. Script install: menu → "9. ShadowTLS";
Docker: add `SHADOWTLS_ENABLE=1` and friends → [Snell + ShadowTLS v3](https://github.com/jinqians/snell/wiki/Docker#b-snell--shadowtls-v3)

ShadowTLS nodes appear in the subscription too (`target=surge`, with `shadow-tls-password` /
`shadow-tls-sni` / `shadow-tls-version = 3`); the Clash targets omit them, since Mihomo's
snell outbound has no shadow-tls plugin.

---

## Repository layout

```
src/            sources (edit these)
  snell.sh        main script: install / menu / config / subscription entry
  lib/*.sh        common / release / netinfo / firewall / channels / conf /
                  routing / subscription (the subscription service, new in v6.4)
snell.sh        generated by tools/build.sh from src/ — do not edit
snell-alpine.sh same, for Alpine
scripts/*.sh    same: menu / multi-user / shadowtls / bbr / snell-docker / install
tools/build.sh  bundles src/ + src/lib into single files; --check verifies freshness
```

```bash
vim src/snell.sh            # or src/lib/*.sh
bash tools/build.sh         # regenerate the published files
bash tools/build.sh --check # verify nothing is stale
```

CI (`.github/workflows/scripts.yml`) checks that generated files match `src/`, that every
script parses (`bash -n`, plus dash / busybox ash for the POSIX ones) and that shellcheck
reports no errors.

---

## Documentation

Features, usage and how it works are in the [upstream wiki](https://github.com/jinqians/snell/wiki)
(the code is the same lineage, so the docs apply):

- [Overview](https://github.com/jinqians/snell/wiki/Overview) — features, repository layout
- [Script install and management](https://github.com/jinqians/snell/wiki/Script-Install-and-Management) — the all-in-one menu, v4 / v5 / v6 side by side, Alpine, the main menu
- [Rule-based routing](https://github.com/jinqians/snell/wiki/Rule-based-Routing) — rule sets with sing-box (the server stays the official snell-server)
- [Docker](https://github.com/jinqians/snell/wiki/Docker) — image tags, ShadowTLS, v6, switching versions, Compose, environment variables
- [Protocols](https://github.com/jinqians/snell/wiki/Protocols) — v4 / v5 / v6, choosing the v6 options, ShadowTLS
- [Surge config](https://github.com/jinqians/snell/wiki/Surge-Config)

---

## Links

- Upstream repo: [jinqians/snell](https://github.com/jinqians/snell) — this project is a fork of it, credits to the original author
- Snell protocol and releases: [kb.nssurge.com](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)
- [Sub-Store](https://github.com/sub-store-rs/sub-store) — subscription manager, can consume this script's endpoint with `source=remote`
- License: [GPL-3.0](LICENSE)
