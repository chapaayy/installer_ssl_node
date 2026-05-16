[Unit]
Description=Remnanode Docker Compose Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/remnanode-stack
ExecStart=/usr/bin/docker compose --project-directory /opt/remnanode-stack up -d --remove-orphans
ExecStop=/usr/bin/docker compose --project-directory /opt/remnanode-stack down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
