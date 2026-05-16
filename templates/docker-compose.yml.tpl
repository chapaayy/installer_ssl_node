name: remnanode-stack

services:
  caddy:
    image: caddy:2
    container_name: remnanode-caddy
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv/site:ro
      - ./logs/caddy:/var/log/caddy
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - edge
    healthcheck:
      test: ["CMD", "caddy", "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "__DOCKER_LOG_MAX_SIZE__"
        max-file: "__DOCKER_LOG_MAX_FILE__"

  fallback-app:
    image: nginx:stable-alpine
    container_name: remnanode-fallback
    restart: unless-stopped
    expose:
      - "80"
    volumes:
      - ./site:/usr/share/nginx/html:ro
    networks:
      - edge
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "__DOCKER_LOG_MAX_SIZE__"
        max-file: "__DOCKER_LOG_MAX_FILE__"

  remnanode:
    image: __REMNANODE_IMAGE__
    container_name: remnanode
    hostname: remnanode
    restart: unless-stopped
    env_file:
      - .env
    network_mode: host
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - ./logs/remnanode:/var/log/remnanode
    logging:
      driver: json-file
      options:
        max-size: "__DOCKER_LOG_MAX_SIZE__"
        max-file: "__DOCKER_LOG_MAX_FILE__"

networks:
  edge:
    name: remnanode-edge
    driver: bridge

volumes:
  caddy_data:
    name: caddy_data
  caddy_config:
    name: caddy_config
