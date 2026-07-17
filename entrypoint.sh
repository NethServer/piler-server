#!/bin/bash
#
# Entrypoint for the rootless piler image. Based on jsuto/piler's
# docker/start.sh (piler is developed at https://github.com/jsuto/piler).
#
set -o errexit
set -o pipefail
set -o nounset

# Secret material (piler.key, .my.cnf, config files carrying the DB password)
# is written here; default to owner-only so there is no world-readable window
# before the explicit chmod 600 in give_it_to_piler.
umask 077

CONFIG_DIR="/etc/piler"
PILER_CONF="${CONFIG_DIR}/piler.conf"
PILER_KEY="${CONFIG_DIR}/piler.key"
PILER_PEM="${CONFIG_DIR}/piler.pem"
PILER_NGINX_CONF="${CONFIG_DIR}/piler-nginx.conf"
SPHINX_CONF="${CONFIG_DIR}/manticore.conf"
CONFIG_SITE_PHP="${CONFIG_DIR}/config-site.php"
PILER_MY_CNF="${CONFIG_DIR}/.my.cnf"
RT="${RT:-0}"
MEMCACHED_HOSTNAME="${MEMCACHED_HOSTNAME:-memcached}"
MANTICORE_HOSTNAME="${MANTICORE_HOSTNAME:-manticore}"
TMP_CONF_DIR="/tmp/piler-conf"
PILER_USER="${PILER_USER:-piler}"

error() {
   echo "ERROR:" "$*" 1>&2
   exit 1
}

log() {
   echo "DEBUG:" "$*"
}

# `sed -i` writes a temp file then renames it over the original, which
# fails with "Device or resource busy" when the target is a bind mount.
# Write into the existing inode instead.
safe_sed() {
   local target="$1"
   shift

   local tmp
   tmp="$(mktemp)"
   sed "$@" "$target" > "$tmp"
   cat "$tmp" > "$target"
   rm -f "$tmp"
}

# Escape a value for safe use as the replacement text in `sed "s<delim>...<delim>"`.
# Backslash, ampersand and the chosen delimiter are special there, so a
# password containing any of them would otherwise break or corrupt the edit.
sed_replacement() {
   local delim="$1" s="$2"
   s="${s//\\/\\\\}"
   s="${s//&/\\&}"
   s="${s//"${delim}"/\\${delim}}"
   printf '%s' "$s"
}

pre_flight_check() {
   [[ -v PILER_HOSTNAME ]] || error "Missing PILER_HOSTNAME env variable"
   [[ -v MYSQL_HOSTNAME ]] || error "Missing MYSQL_HOSTNAME env variable"
   [[ -v MYSQL_DATABASE ]] || error "Missing MYSQL_DATABASE env variable"
   [[ -v MYSQL_USER ]]     || error "Missing MYSQL_USER env variable"
   [[ -v MYSQL_PASSWORD ]] || error "Missing MYSQL_PASSWORD env variable"
   [[ "$RT" =~ ^[01]$ ]]   || error "RT must be 0 or 1, got '${RT}'"
}

give_it_to_piler() {
   local f="$1"

   [[ -f "$f" ]] || error "${f} does not exist, aborting"

   chown "${PILER_USER}:${PILER_USER}" "$f"
   chmod 600 "$f"
}

make_certificate() {
   local f="$1"
   local crt="/tmp/1.cert"
   local SSL_CERT_DATA="/C=US/ST=Denial/L=Springfield/O=Dis/CN=www.example.com"

   log "Making an ssl certificate"

   openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "$SSL_CERT_DATA" -keyout "$f" -out "$crt" -sha256 2>/dev/null
   cat "$crt" >> "$f"
   rm -f "$crt"

   give_it_to_piler "$f"
}

make_piler_key() {
   local f="$1"

   log "Generating piler.key"

   dd if=/dev/urandom bs=56 count=1 of="$f" 2>/dev/null
   [[ $(stat -c '%s' "$f") -eq 56 ]] || error "could not read 56 bytes from /dev/urandom to ${f}"

   give_it_to_piler "$f"
}

write_piler_nginx_conf() {
   log "Writing ${PILER_NGINX_CONF}"

   cp "${TMP_CONF_DIR}/piler-nginx.conf.dist" "$PILER_NGINX_CONF"
   safe_sed "$PILER_NGINX_CONF" "s%PILER_HOST%${PILER_HOSTNAME}%"
}

fix_configs() {
   [[ -f "$PILER_KEY" ]] || make_piler_key "$PILER_KEY"
   [[ -f "$PILER_PEM" ]] || make_certificate "$PILER_PEM"

   [[ -f /etc/piler/MANTICORE ]] || touch /etc/piler/MANTICORE

   # Templates always come from TMP_CONF_DIR, never from the /etc/piler
   # volume itself, or a stale one would never pick up an image update.
   [[ -f /etc/piler/manticore.conf ]] || cp "${TMP_CONF_DIR}/manticore.conf" /etc/piler

   # Also regenerate if an older template left it without a listen directive.
   if [[ ! -f "$PILER_NGINX_CONF" ]] || ! grep -q '^\s*listen\s' "$PILER_NGINX_CONF"; then
      write_piler_nginx_conf
   fi

   if [[ ! -f "$PILER_CONF" ]]; then
      cp "${TMP_CONF_DIR}/piler.conf.dist" "$PILER_CONF"
   fi

   log "Updating ${PILER_CONF}"

   # The password may contain sed-special characters; escape it per delimiter.
   local mysql_pass_slash mysql_pass_pct
   mysql_pass_slash="$(sed_replacement / "$MYSQL_PASSWORD")"
   mysql_pass_pct="$(sed_replacement % "$MYSQL_PASSWORD")"

   safe_sed "$PILER_CONF" \
      -e "s/mysqlhost=.*/mysqlhost=${MYSQL_HOSTNAME}/g" \
      -e "s/mysqluser=.*/mysqluser=${MYSQL_USER}/g" \
      -e "s/mysqldb=.*/mysqldb=${MYSQL_DATABASE}/g" \
      -e "s/verystrongpassword/${mysql_pass_slash}/g" \
      -e "s/hostid=.*/hostid=${PILER_HOSTNAME}/g" \
      -e "s/tls_enable=.*/tls_enable=1/g" \
      -e "s/sphxhost=.*/sphxhost=${MANTICORE_HOSTNAME}/g" \
      -e "s/rtindex=.*/rtindex=${RT}/g" \
      -e "s/mysqlsocket=.*/mysqlsocket=/g" \
      -e "s%pidfile=.*%pidfile=/var/piler/run/piler.pid%g"

   give_it_to_piler "$PILER_CONF"

   if [[ ! -f "$CONFIG_SITE_PHP" ]]; then
      log "Writing ${CONFIG_SITE_PHP}"

      cp "${TMP_CONF_DIR}/config-site.dist.php" "$CONFIG_SITE_PHP"

      safe_sed "$CONFIG_SITE_PHP" "s%HOSTNAME%${PILER_HOSTNAME}%"

      {
         echo "\$config['DECRYPT_BINARY'] = '/usr/bin/pilerget';"
         echo "\$config['DECRYPT_ATTACHMENT_BINARY'] = '/usr/bin/pileraget';"
         echo "\$config['PILER_BINARY'] = '/usr/sbin/piler';"
         echo "\$config['DB_HOSTNAME'] = '$MYSQL_HOSTNAME';"
         echo "\$config['DB_DATABASE'] = '$MYSQL_DATABASE';"
         echo "\$config['DB_USERNAME'] = '$MYSQL_USER';"
         echo "\$config['DB_PASSWORD'] = '$MYSQL_PASSWORD';"
         echo "\$config['MEMCACHED_ENABLED'] = 1;"
         echo "\$memcached_server = ['$MEMCACHED_HOSTNAME', 11211];"
      } >> "$CONFIG_SITE_PHP"
   fi

   safe_sed "$SPHINX_CONF" \
      -e "s%MYSQL_HOSTNAME%${MYSQL_HOSTNAME}%" \
      -e "s%MYSQL_DATABASE%${MYSQL_DATABASE}%" \
      -e "s%MYSQL_USERNAME%${MYSQL_USER}%" \
      -e "s%MYSQL_PASSWORD%${mysql_pass_pct}%"

   # Fixes for RT index

   if [[ $RT -eq 1 ]]; then
      safe_sed "$SPHINX_CONF" "s/define('RT', 0)/define('RT', 1)/"
      if ! grep -q "'RT'" "$CONFIG_SITE_PHP"; then
         echo "\$config['RT'] = 1;" >> "$CONFIG_SITE_PHP"
      fi

      if ! grep -q "'SPHINX_MAIN_INDEX'" "$CONFIG_SITE_PHP"; then
         echo "\$config['SPHINX_MAIN_INDEX'] = 'piler1';" >> "$CONFIG_SITE_PHP"
      fi
   fi

   if ! grep -q "'SPHINX_HOSTNAME'" "$CONFIG_SITE_PHP"; then
      echo "\$config['SPHINX_HOSTNAME'] = '${MANTICORE_HOSTNAME}:9306';" >> "$CONFIG_SITE_PHP"
   fi

   if ! grep -q "'SPHINX_HOSTNAME_READONLY'" "$CONFIG_SITE_PHP"; then
      echo "\$config['SPHINX_HOSTNAME_READONLY'] = '${MANTICORE_HOSTNAME}:9307';" >> "$CONFIG_SITE_PHP"
   fi

   # Fix for PATH_PREFIX
   if [[ -v PATH_PREFIX ]]; then
      log "PATH_PREFIX set $PATH_PREFIX"
      safe_sed /var/piler/www/assets/js/piler.js -e "s#location.origin\ +\ .*#location.origin\ +\ $PATH_PREFIX,#"
      safe_sed "$CONFIG_SITE_PHP" -e "s#^\$config\['PATH_PREFIX'\].*#\$config\['PATH_PREFIX'\] = '$PATH_PREFIX';#"
   fi

   # Both files carry the DB password in plaintext; lock them to piler:piler
   # 600 like piler.conf and .my.cnf, instead of leaving template permissions.
   give_it_to_piler "$CONFIG_SITE_PHP"
   give_it_to_piler "$SPHINX_CONF"
}

wait_until_mysql_server_is_ready() {
   local attempts=0
   local max_attempts="${MYSQL_WAIT_MAX_ATTEMPTS:-60}"

   until mysql "--defaults-file=${PILER_MY_CNF}" <<< "show databases" >/dev/null 2>&1; do
      attempts=$((attempts + 1))
      if [[ "$attempts" -ge "$max_attempts" ]]; then
         error "${MYSQL_HOSTNAME} not ready after ${max_attempts} attempts, giving up"
      fi
      log "${MYSQL_HOSTNAME} is not ready (${attempts}/${max_attempts})"
      sleep 5
   done

   log "${MYSQL_HOSTNAME} is ready"
}

init_database() {
   local table
   local has_metadata_table=0

   wait_until_mysql_server_is_ready

   while read -r table; do
      if [[ "$table" == metadata ]]; then has_metadata_table=1; fi
   done < <(mysql "--defaults-file=${PILER_MY_CNF}" "$MYSQL_DATABASE" <<< 'show tables')

   if [[ $has_metadata_table -eq 0 ]]; then
      log "no metadata table, creating tables"

      mysql "--defaults-file=${PILER_MY_CNF}" "$MYSQL_DATABASE" < /usr/share/piler/db-mysql.sql
   else
      log "metadata table exists"
   fi

   if [[ -v ADMIN_USER_PASSWORD_HASH ]]; then
      # Double any single quote so the hash can't break out of the SQL literal.
      local admin_hash="${ADMIN_USER_PASSWORD_HASH//\'/\'\'}"
      mysql "--defaults-file=${PILER_MY_CNF}" "$MYSQL_DATABASE" <<< "update user set password='${admin_hash}' where uid=0"
   fi
}

create_my_cnf_files() {
   # Ubuntu 26.04's mariadb-client defaults to requiring TLS on TCP
   # connections; the mariadb server in the compose stack has no SSL
   # configured, so the connection is refused.
   printf "[client]\nhost = %s\nuser = %s\npassword = %s\nssl = false\n[mysqldump]\nhost = %s\nuser = %s\npassword = %s\nssl = false\n" \
      "$MYSQL_HOSTNAME" "$MYSQL_USER" "$MYSQL_PASSWORD" "$MYSQL_HOSTNAME" "$MYSQL_USER" "$MYSQL_PASSWORD" \
      > "$PILER_MY_CNF"

   give_it_to_piler "$PILER_MY_CNF"
}

start_piler() {
   # piler.conf's default pidfile path (/var/run/piler/piler.pid) never
   # gets created, so the pidfile is never written and `rc.piler status`
   # always reports "NOT running" even though the daemon is up.
   # fix_configs() redirects pidfile= to /var/piler/run/piler.pid, so
   # make sure that directory exists too.
   mkdir -p /var/piler/run

   # No pid file should exist for piler
   rm -f /var/piler/run/*pid

   /etc/init.d/rc.piler start
}

pre_flight_check
fix_configs
create_my_cnf_files
init_database
start_piler

exec "$@"
