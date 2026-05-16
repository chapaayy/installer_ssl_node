{
	email {$ACME_EMAIL}

	log {
		output file /var/log/caddy/default.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		format json
		level INFO
	}
}

{$DOMAIN} {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	root * /srv/site
	try_files {path} /index.html
	file_server

	log {
		output file /var/log/caddy/access.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		format json
	}
}
