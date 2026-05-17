# Remnanode stack bootstrap

Named mode:

```bash
curl -fsSL https://raw.githubusercontent.com/chapaayy/installer_ssl_node/main/bootstrap.sh | sudo bash -s -- \
  --panel-api-token "TOKEN" \
  --acme-email "admin@example.com" \
  --panel-domain "panel.example.com" \
  --config-profile-uuid "PROFILE_UUID" \
  --active-inbounds "INBOUND_UUID1,INBOUND_UUID2" \
  --domain "node1.example.com" \
  --auto-install
```

Positional mode:

```bash
curl -fsSL https://raw.githubusercontent.com/chapaayy/installer_ssl_node/main/bootstrap.sh | sudo bash -s -- \
  "TOKEN" \
  "admin@example.com" \
  "panel.example.com" \
  "PROFILE_UUID" \
  "INBOUND_UUID1,INBOUND_UUID2" \
  "node1.example.com" \
  --auto-install
```

Positional order:

1. `PANEL_API_TOKEN`
2. `ACME_EMAIL`
3. `PANEL_DOMAIN`
4. `PANEL_CONFIG_PROFILE_UUID`
5. `PANEL_ACTIVE_INBOUND_UUIDS`
6. `DOMAIN`

For the next node you usually change only the last argument: `DOMAIN`.

Warning: command-line tokens can be saved in shell history, terminal logs, process lists, or automation logs. Use a short-lived token where possible.

The bootstrap script downloads this repository by default: `https://github.com/chapaayy/installer_ssl_node.git`.

Install order follows the GitHub installer flow, adapted for nginx:

1. Network tuning and limits.
2. Base packages.
3. Docker and Docker logging.
4. Remnanode.
5. nginx and SSL.
6. Firewall.
7. Fail2ban.

After install, manage the node with:

```bash
sudo remnanode-stack help
```

Firewall opens SSH, 80/tcp for ACME, public TLS/inbound ports `443/tcp`, `4443/tcp`, `8443/tcp`, `9443/tcp`, and `NODE_PORT` for the panel connection.

Log retention defaults are conservative: nginx/install logs and remnanode file logs rotate daily, compressed archives older than `31` days are removed, Docker json logs are capped by `DOCKER_LOG_MAX_SIZE` x `DOCKER_LOG_MAX_FILE`, and journald gets a 31-day retention drop-in.
