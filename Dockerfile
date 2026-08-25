# syntax=docker/dockerfile:1

ARG BASE_IMAGE=ubuntu:resolute-20260610
ARG PILER_VERSION=1.4.9
# amd64-only image. sha256 of the amd64 .deb - on a version bump, copy the new
# asset digest from the release page (each asset shows a sha256):
#   https://github.com/jsuto/piler/releases  (open the piler-<version> tag)
ARG PILER_SHA256=e6f9e5e7bf307f024ea248352b93d5cad0925f0f998b2902e0e64ce0db51859a
ARG SUPERCRONIC_VERSION=v0.2.46
# sha256 of the amd64 binary, from the release page:
#   https://github.com/aptible/supercronic/releases  (open the <version> tag)
ARG SUPERCRONIC_SHA256=5adff01c5a797663948e656d2b61d10932369ee437eb5cb54fa872b2960f222b

# --- stage: fetcher ---------------------------------------------------------
FROM ${BASE_IMAGE} AS fetcher

ARG PILER_VERSION
ARG TARGETARCH
ARG PILER_SHA256
ARG SUPERCRONIC_VERSION
ARG SUPERCRONIC_SHA256

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /fetch

# This image is built for amd64 only; fail fast on any other target arch
# rather than fetching amd64 artifacts into a mislabelled image.
RUN [ "${TARGETARCH:-amd64}" = "amd64" ] || { echo "unsupported TARGETARCH=${TARGETARCH}, only amd64 is built" >&2; exit 1; }

# The .deb filename embeds a build commit hash we don't track
# ("piler_1.4.9-resolute-d3f4b07_amd64.deb") - resolve it from the
# GitHub release's asset list instead of hardcoding it, so Renovate only
# has to bump PILER_VERSION.
RUN url=$(curl -fsSL "https://api.github.com/repos/jsuto/piler/releases/tags/piler-${PILER_VERSION}" \
             | grep -o "https://github.com/jsuto/piler/releases/download/[^\"]*_amd64\.deb" \
             | head -n1) && \
    curl -fsSLo piler.deb "$url" && \
    echo "${PILER_SHA256}  piler.deb" | sha256sum -c -

RUN curl -fsSLo supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" && \
    echo "${SUPERCRONIC_SHA256}  supercronic" | sha256sum -c - && \
    chmod +x supercronic

# --- stage: runtime ----------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

# Re-declare in this stage so it can be used in the version label below;
# otherwise the base image's own image.version (Ubuntu's) leaks through.
ARG PILER_VERSION

LABEL org.opencontainers.image.source="https://github.com/NethServer/piler-server" \
      org.opencontainers.image.authors="Stephane de Labrusse <stephdl@de-labrusse.fr>" \
      org.opencontainers.image.title="piler mail archiving server" \
      org.opencontainers.image.description="Rootless piler (email archiver) image: nginx, php-fpm and supervisord, running against external mariadb, manticore and memcached containers" \
      org.opencontainers.image.version="${PILER_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.vendor="NethServer"

ENV DEBIAN_FRONTEND="noninteractive" \
    PILER_USER="piler" \
    MYSQL_DATABASE="piler"

# hadolint ignore=DL3008
RUN if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
       openssl sysstat bsdextrautils catdoc unrtf poppler-utils tnef libtre5 ca-certificates \
       mariadb-client-core python3 python3-mysqldb libzip5 \
       curl nginx \
       php-cli php-cgi php-mysql php-fpm php-zip php-ldap php-gd php-curl php-xml php-memcached \
       supervisor && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY --from=fetcher /fetch/piler.deb /tmp/piler.deb
COPY --from=fetcher /fetch/supercronic /usr/local/bin/supercronic

# piler's own postinst creates the "piler" system user - let it, then pin
# its uid/gid to a fixed value so bind-mounted host directories keep
# stable ownership across rebuilds/hosts.
RUN dpkg -i /tmp/piler.deb && \
    rm -f /tmp/piler.deb && \
    groupmod -g 1000 piler && \
    usermod -u 1000 -g 1000 -s /usr/sbin/nologin piler && \
    touch /etc/piler/MANTICORE && \
    ln -sf /etc/piler/piler-nginx.conf /etc/nginx/sites-enabled/piler-nginx.conf && \
    rm -f /etc/nginx/sites-enabled/default /etc/piler/piler.key /etc/piler/piler.pem /etc/piler/config-site.php && \
    mkdir -p /var/piler/run && \
    grep -v 'indexer' /usr/share/piler/piler.cron > /etc/piler.cron

# nginx and php-fpm run as the same unprivileged piler user (no root to drop
# from). Their default pidfiles/sockets live under root-owned /run/php, which a
# non-root process can't populate at start - relocate them to /var/piler/run,
# owned by piler in the writable layer.
RUN sed -i -E \
      -e '/^\s*user\s+\S+;/d' \
      -e 's%^pid\s+/run/nginx\.pid;%pid /var/piler/run/nginx.pid;%' \
      /etc/nginx/nginx.conf && \
    # stream logs to the container's own stdout/stderr instead of files,
    # so podman/journald capture them and nothing accumulates on disk.
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log && \
    sed -i -E \
      -e 's%^pid\s*=.*%pid = /var/piler/run/php-fpm.pid%' \
      -e 's%^error_log\s*=.*%error_log = /dev/stderr%' \
      /etc/php/*/fpm/php-fpm.conf && \
    find /etc/php -name 'www.conf' -exec \
      sed -i -E \
        -e '/^(user|group)\s*=/d' \
        -e 's%^listen\s*=.*%listen = /var/piler/run/php-fpm.sock%' \
        -e 's/^listen\.owner\s*=.*/listen.owner = piler/' \
        -e 's/^listen\.group\s*=.*/listen.group = piler/' \
        {} \; && \
    sed -i -E 's%unix:/run/php/[^;]*\.sock%unix:/var/piler/run/php-fpm.sock%' \
      /etc/piler/piler-nginx.conf.dist && \
    sed -i -E '0,/^server \{/s//server {\n        listen 80 default_server;\n        listen [::]:80 default_server;/' \
      /etc/piler/piler-nginx.conf.dist && \
    ln -sf "$(ls /usr/sbin/php-fpm* | head -n1)" /usr/local/bin/php-fpm && \
    chown -R piler:piler /etc/piler /var/piler /var/log/nginx /var/lib/nginx && \
    # entrypoint.sh reads *.dist templates from this snapshot, never from
    # /etc/piler itself (a VOLUME, so it'd go stale on an existing one).
    # Take it after the sed fixes above, or it ships pre-fix config.
    cp -R /etc/piler /tmp/piler-conf && \
    # Nothing reads *.dist from the volume anymore - drop them from it.
    rm -f /etc/piler/*.dist

COPY entrypoint.sh /entrypoint.sh
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/exit-on-fatal-listener.py /etc/supervisor/exit-on-fatal-listener.py
COPY config/piler-run.sh /etc/supervisor/piler-run.sh
RUN chmod +x /entrypoint.sh /etc/supervisor/piler-run.sh && \
    chown -R piler:piler /tmp/piler-conf && \
    chown piler:piler /entrypoint.sh /etc/supervisor/supervisord.conf /etc/supervisor/exit-on-fatal-listener.py /etc/supervisor/piler-run.sh

VOLUME ["/etc/piler", "/var/piler/store"]

EXPOSE 25 80 443

# Probing the web UI alone would report healthy with mail intake dead.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://localhost/ >/dev/null && curl -fsS --max-time 3 smtp://localhost:25/ >/dev/null || exit 1

USER piler

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
