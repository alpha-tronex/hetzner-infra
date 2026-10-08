# assistant.alphatronex.com — personal-assistant container (127.0.0.1:8000).
# Live copy: /etc/nginx/sites-available/assistant.alphatronex.com (Certbot
# manages the ssl lines; copy any rewrite back here).
#
# Auth is enforced by the app itself (login page + session cookie, see
# Personal-Assistant/backend/app/auth.py). /healthz and /reauth* stay public.
server {
    server_name assistant.alphatronex.com;

    # Only the host-level WhatsApp bridge may call these, and it talks to
    # 127.0.0.1:8000 directly — never through nginx. Blocking them here stops
    # the internet from injecting fake DMs (the app exempts them from login).
    location ^~ /whatsapp/ {
        return 404;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }

    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/assistant.alphatronex.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/assistant.alphatronex.com/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

}
server {
    if ($host = assistant.alphatronex.com) {
        return 301 https://$host$request_uri;
    } # managed by Certbot


    listen 80;
    server_name assistant.alphatronex.com;
    return 404; # managed by Certbot


}
