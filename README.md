# hetzner-infra

Infrastructure docs and config for the Hetzner box (5.161.104.5) that hosts multiple
unrelated apps behind a shared nginx + Certbot reverse proxy.

- [`hetzner.md`](./hetzner.md) — server diagram, services, ports, persistent storage
- [`nginx/`](./nginx) — vhost configs per subdomain

Currently hosted:
- personal-assistant (source: [Personal-Assistant repo](https://github.com/alpha-tronex/Personal-Assistant))
- uptime-kuma
- vaultwarden
- FAIS (migrating from Render — source: FAIS repo)
- Real Dosing — supplement price comparison (static site, https://dosinghub.com, source: supplement-price-app repo)
