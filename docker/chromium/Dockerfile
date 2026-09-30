# Headless Chromium with the sandbox's egress CA trusted, exposed over CDP.
#
# Why this exists: in the Claude Code cloud environment, host-side Chromium
# cannot complete a TLS handshake through the agent proxy's CONNECT relay --
# every navigation dies as net::ERR_CONNECTION_RESET. Container egress takes a
# different path (transparent interception by the sandbox egress gateway) that
# works fine, so the browser runs here and playwright-cli drives it over CDP
# via browser.cdpEndpoint.
#
# Note the two interception CAs are NOT the same: the host proxy presents
# "CCR agent-proxy interception CA" while container traffic is re-signed by
# "sandbox-egress-gateway ... Egress Gateway CA". Only /root/.ccr/ca-bundle.crt
# carries both, so the whole bundle is what gets installed -- into the OpenSSL
# store for apt/curl AND into the NSS shared DB, which is what Chromium on
# Linux actually reads. The base image ships no CA store at all, so
# ca-certificates goes in first; Debian's apt repos are plain HTTP and need no
# trust to reach.
FROM chromedp/headless-shell:latest

# Full trust bundle, copied into the build context by setup-env.sh.
COPY ca-bundle.crt /usr/local/share/ca-certificates/ccr-ca-bundle.crt

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libnss3-tools \
 && update-ca-certificates \
 && mkdir -p /root/.pki/nssdb \
 && certutil -d sql:/root/.pki/nssdb -N --empty-password \
 && mkdir -p /tmp/ca-split \
 && awk 'BEGIN{n=0} /BEGIN CERT/{n++} {print > ("/tmp/ca-split/cert-" n ".pem")}' \
      /usr/local/share/ca-certificates/ccr-ca-bundle.crt \
 && for f in /tmp/ca-split/cert-*.pem; do \
      certutil -d sql:/root/.pki/nssdb -A -t "C,," -n "ccr-$(basename "$f" .pem)" -i "$f" || true; \
    done \
 && rm -rf /tmp/ca-split /var/lib/apt/lists/*
