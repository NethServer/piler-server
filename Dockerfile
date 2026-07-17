# syntax=docker/dockerfile:1

ARG BASE_IMAGE=ubuntu:resolute-20260610
ARG PILER_VERSION=1.4.9
ARG SUPERCRONIC_VERSION=v0.2.46
ARG SUPERCRONIC_SHA1SUM_AMD64=5bcefed628e32adc08e32634db2d10e9230dbca0
ARG SUPERCRONIC_SHA1SUM_ARM64=639ab81a72771990790df7ee87d9acfe88e5fa83

# --- stage: fetcher ---------------------------------------------------------
FROM ${BASE_IMAGE} AS fetcher

ARG PILER_VERSION
ARG TARGETARCH
ARG SUPERCRONIC_VERSION
ARG SUPERCRONIC_SHA1SUM_AMD64
ARG SUPERCRONIC_SHA1SUM_ARM64

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /fetch

# The .deb filename embeds a build commit hash we don't track
# ("piler_1.4.9-resolute-d3f4b07_amd64.deb") - resolve it from the
# GitHub release's asset list instead of hardcoding it, so Renovate only
# has to bump PILER_VERSION.
RUN url=$(curl -fsSL "https://api.github.com/repos/jsuto/piler/releases/tags/piler-${PILER_VERSION}" \
             | grep -o "https://github.com/jsuto/piler/releases/download/[^\"]*_${TARGETARCH}\.deb" \
             | head -n1) && \
    curl -fsSLo piler.deb "$url"

RUN curl -fsSLo supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" && \
    if [ "${TARGETARCH}" = "arm64" ]; then sum="${SUPERCRONIC_SHA1SUM_ARM64}"; else sum="${SUPERCRONIC_SHA1SUM_AMD64}"; fi && \
    echo "${sum}  supercronic" | sha1sum -c - && \
    chmod +x supercronic

# --- stage: runtime ----------------------------------------------------------
FROM ${BASE_IMAGE} AS runtime

LABEL description="piler mail archiving server, rootless image" \
      maintainer="Stephane de Labrusse"

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
    cp /usr/share/piler/piler.cron /etc/piler.cron

# nginx and php-fpm must run as the same unprivileged user as everything
# else - there is no root left to drop privileges from. Their default
# pidfiles/sockets also live under /run/php, which is root-owned tmpfs
# that a non-root process can't create subdirectories in at container
# start - relocate them into /var/piler/run instead, which is owned by
# piler and part of the container's own writable layer.
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
RUN chmod +x /entrypoint.sh && \
    chown -R piler:piler /tmp/piler-conf && \
    chown piler:piler /entrypoint.sh /etc/supervisor/supervisord.conf /etc/supervisor/exit-on-fatal-listener.py

VOLUME ["/etc/piler", "/var/piler/store"]

EXPOSE 25 80 443

# Liveness: nginx serving the web UI means supervisord and php-fpm are up.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://localhost/ >/dev/null || exit 1

USER piler

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
