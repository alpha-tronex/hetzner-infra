# demo.alphatronex.com — public demo of the personal assistant
# (personal-assistant-demo container, 127.0.0.1:8001, DEMO_MODE=true).
# Sample data only, no login, no credentials; see
# Personal-Assistant/backend/app/demo.py.
#
# Install HTTP-only first, then `sudo certbot --nginx -d demo.alphatronex.com`
# adds the 443/ssl lines — copy the result back into this file afterwards.

# Public and login-free, so throttle per client IP. (limit_req_zone is valid
# here: sites-enabled/* is included inside nginx.conf's http block.)
limit_req_zone $binary_remote_addr zone=pa_demo:10m rate=5r/s;

server {
    server_name demo.alphatronex.com;

    client_max_body_size 64k;

    # The app already 404s these in demo mode; block them here as well.
    location ^~ /whatsapp/ { return 404; }
    location ^~ /reauth { return 404; }

    location / {
        limit_req zone=pa_demo burst=20 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }

    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/demo.alphatronex.com/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/demo.alphatronex.com/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

}


server {
    if ($host = demo.alphatronex.com) {
        return 301 https://$host$request_uri;
    } # managed by Certbot


    listen 80;
    server_name demo.alphatronex.com;
    return 404; # managed by Certbot


}
