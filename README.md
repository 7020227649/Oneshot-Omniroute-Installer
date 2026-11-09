# One-Shot OmniRoute Installer - 1 GB Oracle Cloud VPS

One-command installer for OmniRoute on Ubuntu 22.04. It installs Docker
Compose, OmniRoute, Redis, Nginx, Let's Encrypt HTTPS, persistence, swap,
health checks, backups, and update helpers.

OmniRoute upstream recommends about 2 GB RAM. This version is tuned for a
1 GB VPS with 2 GB swap and a 512 MB V8 heap. It is intended for light,
single-user traffic; heavy parallel coding-agent traffic may need more RAM.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/7020227649/Oneshot-Omniroute-Installer/main/install.sh | sudo bash
```

The installer asks for a domain, email, and dashboard password. Requirements:
fresh Ubuntu 22.04, 768 MB+ RAM, DNS A record, and Oracle Cloud ingress rules
for TCP 80 and 443.

## Commands

```bash
sudo omniroute-status
sudo omniroute-logs
sudo omniroute-restart
sudo omniroute-update
sudo omniroute-backup
```

Installation progress:

```bash
sudo journalctl -fu one-shot-omniroute-install.service
```

The app and Redis are never exposed publicly. Nginx is the only public entry
point and HTTPS is enabled through Let's Encrypt.
