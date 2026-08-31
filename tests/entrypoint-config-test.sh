#!/bin/bash
#
# Offline tests for entrypoint.sh's config generation: fix_configs() driven
# against a throwaway CONFIG_DIR, no container and no database.
#
set -o errexit
set -o pipefail
set -o nounset

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${HERE}/../entrypoint.sh"

# One boot, in its own process, so each case starts as a container start does.
if [[ "${1:-}" == "--boot" ]]; then
   # shellcheck source=../entrypoint.sh
   source "$ENTRYPOINT"

   # chown needs root; the chmod stays so the mode assertions still mean
   # something.
   give_it_to_piler() {
      [[ -f "$1" ]] || error "${1} does not exist, aborting"
      chmod 600 "$1"
   }
   # A 4096-bit key per boot would dominate the runtime.
   make_certificate() { : > "$1"; }

   # Both write files and need no database, unlike init_database.
   fix_configs
   create_my_cnf_files
   exit 0
fi

failures=0

ok() { printf 'ok   %s\n' "$1"; }
ko() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

check_eq() {
   local what="$1" want="$2" got="$3"
   if [[ "$want" == "$got" ]]; then ok "$what"; else
      ko "$what"
      printf '       want: %s\n       got : %s\n' "$want" "$got" >&2
   fi
}

check_file_has() {
   local what="$1" file="$2" pattern="$3"
   if grep -qF -- "$pattern" "$file"; then ok "$what"; else
      ko "$what"
      printf '       %s does not contain: %s\n' "$file" "$pattern" >&2
   fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TMPL="${WORK}/templates"
mkdir -p "$TMPL"

# Stand-ins for the .dist files the image ships. The key names must match the
# shipped template exactly; cross-check with:
#   podman run --rm --entrypoint /bin/sh <image> \
#     -c 'grep -E "^(mysql|hostid|tls_enable|sphxhost|rtindex)" \
#         /tmp/piler-conf/piler.conf.dist'
cat > "${TMPL}/piler.conf.dist" <<'EOF'
[piler]
mysql_connect_timeout=2
mysqlcharset=utf8mb4
mysqldb=piler
mysqlhost=
mysqlpwd=verystrongpassword
mysqlsocket=/var/run/mysqld/mysqld.sock
mysqluser=piler
hostid=localhost
tls_enable=0
sphxhost=127.0.0.1
rtindex=0
pidfile=/var/run/piler/piler.pid
EOF

# No trailing newline, like the shipped template: that is what swallows the
# marker line.
printf '<?php\n$config = [];' > "${TMPL}/config-site.dist.php"

cat > "${TMPL}/piler-nginx.conf.dist" <<'EOF'
server {
    listen 80;
    server_name PILER_HOST;
}
EOF

# One boot in a fresh process. Extra "VAR=value" arguments are exported on top.
boot() {
   local config_dir="$1" password="$2"
   shift 2

   # Mirrors the shipped asset: "    base_url: location.origin + '/',".
   # KEEP_JS=1 leaves whatever the caller put there, to test a broken asset.
   local js="${config_dir}/piler.js"
   if [[ "${KEEP_JS:-0}" != 1 ]]; then
      printf "    base_url: location.origin + '/',\n" > "$js"
   fi

   (
      export CONFIG_DIR="$config_dir" TMP_CONF_DIR="$TMPL" PILER_JS="$js"
      export PILER_HOSTNAME="piler.example.com"
      export MYSQL_HOSTNAME="mysql" MYSQL_DATABASE="piler" MYSQL_USER="piler"
      export MYSQL_PASSWORD="$password"
      export MEMCACHED_HOSTNAME="memcached" MANTICORE_HOSTNAME="manticore"
      local kv
      for kv in "$@"; do export "${kv?}"; done
      bash "${BASH_SOURCE[0]}" --boot > /dev/null
   )
}

new_dir() {
   local d
   d="$(mktemp -d "${WORK}/case-XXXXXX")"
   printf '%s' "$d"
}

# Only PHP itself can tell the intended value from a convincing lookalike.
php_value() {
   php -r 'include $argv[1]; echo $config[$argv[2]];' "$1" "$2"
}

# Pure functions, so a table states exactly what each grammar needs.
escaper_out() {
   local fn="$1"
   shift
   (
      # shellcheck source=../entrypoint.sh
      source "$ENTRYPOINT"
      "$fn" "$@"
   )
}

check_escaper() {
   local fn="$1" input="$2" want="$3"
   shift 3
   check_eq "${fn} $(printf '%q' "$input")" "$want" "$(escaper_out "$fn" "$@" "$input")"
}

echo "# each escaper matches its destination grammar"

# PHP single-quoted: only backslash and quote are special.
check_escaper php_single_quoted "plain"    "plain"
check_escaper php_single_quoted "a'b"      "a\\'b"
check_escaper php_single_quoted 'a\b'      'a\\b'
check_escaper php_single_quoted 'a#b"c$d'  'a#b"c$d'
# An already-escaped value gets escaped again, not passed through.
check_escaper php_single_quoted "a\\'b"    "a\\\\\\'b"

# Always quoted: unquoted, '#' comments and a trailing space is trimmed.
check_escaper my_cnf_value "plain"   '"plain"'
check_escaper my_cnf_value "a#b"     '"a#b"'
check_escaper my_cnf_value "ab "     '"ab "'
check_escaper my_cnf_value 'a\b'     '"a\\b"'
check_escaper my_cnf_value 'a"b'     '"a\"b"'
check_escaper my_cnf_value "a'b"     '"a'"'"'b"'

# MariaDB interprets backslash inside literals, so doubling the quote is not
# enough.
check_escaper sql_literal "plain"  "plain"
check_escaper sql_literal "a'b"    "a''b"
check_escaper sql_literal 'a\b'    'a\\b'
check_escaper sql_literal '$2y$10$x\y'  '$2y$10$x\\y'

# The ampersand is the dangerous one: sed replaces it with the whole match.
check_escaper sed_replacement "plain"  "plain"  /
check_escaper sed_replacement "a&b"    'a\&b'   /
check_escaper sed_replacement "a/b"    'a\/b'   /
check_escaper sed_replacement "a/b"    "a/b"    %
check_escaper sed_replacement "a%b"    'a\%b'   %
check_escaper sed_replacement 'a\b'    'a\\b'   /

echo "# a first boot writes the generated config"

d="$(new_dir)"
boot "$d" 'piler123'
check_eq "piler.conf carries the password" \
   "mysqlpwd=piler123" "$(grep '^mysqlpwd=' "${d}/piler.conf")"
check_eq "piler.conf carries the host" \
   "mysqlhost=mysql" "$(grep '^mysqlhost=' "${d}/piler.conf")"
check_eq "rtindex is forced to 1" \
   "rtindex=1" "$(grep '^rtindex=' "${d}/piler.conf")"
check_file_has "config-site.php carries the password" \
   "${d}/config-site.php" "\$config['DB_PASSWORD'] = 'piler123';"
check_file_has "config-site.php points at manticore" \
   "${d}/config-site.php" "\$config['SPHINX_HOSTNAME'] = 'manticore:9306';"
check_file_has "config-site.php keeps RELOAD_COMMAND" \
   "${d}/config-site.php" "rc.piler reload"
check_eq "the marker survived a template with no trailing newline" \
   "1" "$(grep -cF 'generated by entrypoint' "${d}/config-site.php")"
check_eq "piler.conf is owner-only" "600" "$(stat -c '%a' "${d}/piler.conf")"
check_eq "config-site.php is owner-only" "600" "$(stat -c '%a' "${d}/config-site.php")"
check_eq "piler.key is 56 bytes" "56" "$(stat -c '%s' "${d}/piler.key")"

echo "# a rotated password reaches both files"

boot "$d" 'rotated-secret'
check_eq "piler.conf picked up the new password" \
   "mysqlpwd=rotated-secret" "$(grep '^mysqlpwd=' "${d}/piler.conf")"
check_file_has "config-site.php picked up the new password" \
   "${d}/config-site.php" "\$config['DB_PASSWORD'] = 'rotated-secret';"
check_eq "the old password is gone from config-site.php" \
   "0" "$(grep -cF 'piler123' "${d}/config-site.php")"

echo "# a renamed service reaches config-site.php"

boot "$d" 'rotated-secret' 'MANTICORE_HOSTNAME=search' 'MEMCACHED_HOSTNAME=cache'
check_file_has "SPHINX_HOSTNAME follows MANTICORE_HOSTNAME" \
   "${d}/config-site.php" "\$config['SPHINX_HOSTNAME'] = 'search:9306';"
check_file_has "the memcached server follows MEMCACHED_HOSTNAME" \
   "${d}/config-site.php" "\$memcached_server = ['cache', 11211];"

echo "# repeated boots neither grow the file nor lose hand edits"

d="$(new_dir)"
boot "$d" 'piler123'
# Above the marker must survive; below it is not preserved, by contract.
sed -i "1a \$config['LANG'] = 'fr';" "${d}/config-site.php"
lines="$(wc -l < "${d}/config-site.php")"
for _ in 1 2 3; do boot "$d" 'piler123'; done
check_eq "the file did not grow over three more boots" \
   "$lines" "$(wc -l < "${d}/config-site.php")"
check_eq "exactly one marker" \
   "1" "$(grep -cF 'generated by entrypoint' "${d}/config-site.php")"
check_file_has "the hand edit above the marker survived" \
   "${d}/config-site.php" "\$config['LANG'] = 'fr';"

echo "# values that are special in PHP or sed are escaped, not injected"

# Both sed delimiters, the replacement ampersand, and PHP that would run if the
# quoting broke.
tricky="a'b&c/d%e\\f\"g\$h"
d="$(new_dir)"
boot "$d" "$tricky"
check_eq "piler.conf holds the password verbatim" \
   "mysqlpwd=${tricky}" "$(grep '^mysqlpwd=' "${d}/piler.conf")"

if command -v php > /dev/null; then
   check_eq "config-site.php is valid PHP" \
      "No syntax errors detected in ${d}/config-site.php" \
      "$(php -l "${d}/config-site.php" 2>&1)"
   check_eq "PHP reads the password back byte for byte" \
      "$tricky" "$(php_value "${d}/config-site.php" DB_PASSWORD)"

   injection="x'; system('touch ${WORK}/pwned'); \$y = '"
   d="$(new_dir)"
   boot "$d" "$injection"
   check_eq "an injection attempt is valid PHP" \
      "No syntax errors detected in ${d}/config-site.php" \
      "$(php -l "${d}/config-site.php" 2>&1)"
   check_eq "the injection is read back as data" \
      "$injection" "$(php_value "${d}/config-site.php" DB_PASSWORD)"
   if [[ -e "${WORK}/pwned" ]]; then
      ko "including config-site.php executed the injected payload"
   else
      ok "including config-site.php executed nothing"
   fi
else
   echo "skip PHP assertions: no php binary"
fi

echo "# an integrated deployment can override the constants but not the topology"

# ns8-piler documents config-site.php.local as the way to customize the web UI,
# and it renders the whole file. Constants have to survive that; values the
# environment decides must not, or a rotated password never reaches the UI.
#
# Counting occurrences is the discriminator: if the image restates a key the
# deployment already set, the file carries it twice and the image's copy wins.
d="$(new_dir)"
boot "$d" 'piler123'
sed -i "/^# generated by entrypoint/,\$d" "${d}/config-site.php"
cat >> "${d}/config-site.php" <<'LOCAL'
$config['RELOAD_COMMAND'] = '/bin/true';
$config['SPHINX_MAIN_INDEX'] = 'custom_index';
$config['MEMCACHED_ENABLED'] = 0;
$config['DB_HOSTNAME'] = 'stale.example.com';
$config['SPHINX_HOSTNAME'] = 'stale.example.com:9306';
LOCAL
boot "$d" 'rotated-secret'

for k in RELOAD_COMMAND SPHINX_MAIN_INDEX MEMCACHED_ENABLED; do
   check_eq "${k} is not restated over the deployment's value" \
      "1" "$(grep -c "config\['${k}'\]" "${d}/config-site.php")"
done

check_file_has "DB_HOSTNAME still follows the environment" \
   "${d}/config-site.php" "\$config['DB_HOSTNAME'] = 'mysql';"
check_file_has "the rotated password still reaches the UI" \
   "${d}/config-site.php" "\$config['DB_PASSWORD'] = 'rotated-secret';"
check_file_has "SPHINX_HOSTNAME still follows the environment" \
   "${d}/config-site.php" "\$config['SPHINX_HOSTNAME'] = 'manticore:9306';"

if command -v php > /dev/null; then
   check_eq "PHP sees the deployment's RELOAD_COMMAND" \
      "/bin/true" "$(php_value "${d}/config-site.php" RELOAD_COMMAND)"
   check_eq "PHP sees the deployment's SPHINX_MAIN_INDEX" \
      "custom_index" "$(php_value "${d}/config-site.php" SPHINX_MAIN_INDEX)"
   check_eq "PHP sees the environment's DB_HOSTNAME, not the stale one" \
      "mysql" "$(php_value "${d}/config-site.php" DB_HOSTNAME)"
   check_eq "PHP sees the rotated password" \
      "rotated-secret" "$(php_value "${d}/config-site.php" DB_PASSWORD)"
fi

# Absent from the file, so the image has to supply them: a standalone install
# has no template to state them.
d="$(new_dir)"
boot "$d" 'piler123'
for k in RT SPHINX_MAIN_INDEX MEMCACHED_ENABLED DECRYPT_BINARY \
         DECRYPT_ATTACHMENT_BINARY PILER_BINARY RELOAD_COMMAND; do
   check_eq "${k} is supplied when nothing states it" \
      "1" "$(grep -c "config\['${k}'\]" "${d}/config-site.php")"
done

echo "# .my.cnf quotes what MariaDB would otherwise truncate"

d="$(new_dir)"
boot "$d" 'pw#with space '
check_eq ".my.cnf quotes the password in [client]" \
   'password = "pw#with space "' "$(grep -m1 '^password' "${d}/.my.cnf")"
check_eq "both sections are present" \
   "2" "$(grep -c '^password' "${d}/.my.cnf")"
check_eq ".my.cnf is owner-only" "600" "$(stat -c '%a' "${d}/.my.cnf")"

d="$(new_dir)"
boot "$d" 'a\b"c'
check_eq ".my.cnf escapes backslash and quote" \
   'password = "a\\b\"c"' "$(grep -m1 '^password' "${d}/.my.cnf")"

echo "# nothing manticore-related is written any more"

d="$(new_dir)"
boot "$d" 'piler123'
check_eq "no manticore.conf in the config dir" \
   "" "$(find "$d" -name 'manticore.conf' -printf '%f\n')"
check_eq "no MANTICORE marker" \
   "" "$(find "$d" -name 'MANTICORE' -printf '%f\n')"
check_eq "no sql_ credentials leaked anywhere" \
   "0" "$(grep -rlE '^[[:space:]]*sql_(host|db|user|pass)' "$d" 2>/dev/null | wc -l)"

echo "# every interpolated value survives sed-special characters"

# Two failure modes: '&' corrupts silently, a delimiter makes sed error out.
echo "#   an ampersand alone corrupts silently"

d="$(new_dir)"
boot "$d" 'piler123' 'PILER_HOSTNAME=piler-x&y.example.com' 'MYSQL_USER=user-a&b'
check_eq "hostid survives an ampersand" \
   "hostid=piler-x&y.example.com" "$(grep '^hostid=' "${d}/piler.conf")"
check_eq "mysqluser survives an ampersand" \
   "mysqluser=user-a&b" "$(grep '^mysqluser=' "${d}/piler.conf")"

echo "#   a delimiter alone breaks the expression"

hostile='x&y/z%w'
d="$(new_dir)"
if ! boot "$d" 'piler123' \
   "PILER_HOSTNAME=piler-${hostile}.example.com" \
   "MYSQL_HOSTNAME=host-${hostile}" \
   "MYSQL_USER=user-${hostile}" \
   "MYSQL_DATABASE=db-${hostile}" \
   "MANTICORE_HOSTNAME=search-${hostile}" 2> /dev/null; then
   ko "a boot with both sed delimiters in every value failed"
else
   ok "a boot with both sed delimiters in every value succeeds"
fi
check_eq "hostid keeps the hostname verbatim" \
   "hostid=piler-${hostile}.example.com" "$(grep '^hostid=' "${d}/piler.conf")"
check_eq "mysqlhost keeps the value verbatim" \
   "mysqlhost=host-${hostile}" "$(grep '^mysqlhost=' "${d}/piler.conf")"
check_eq "mysqluser keeps the value verbatim" \
   "mysqluser=user-${hostile}" "$(grep '^mysqluser=' "${d}/piler.conf")"
check_eq "mysqldb keeps the value verbatim" \
   "mysqldb=db-${hostile}" "$(grep '^mysqldb=' "${d}/piler.conf")"
check_eq "sphxhost keeps the value verbatim" \
   "sphxhost=search-${hostile}" "$(grep '^sphxhost=' "${d}/piler.conf")"
check_eq "pidfile is still set, now through the escaped path" \
   "pidfile=/var/piler/run/piler.pid" "$(grep '^pidfile=' "${d}/piler.conf")"
check_file_has "the nginx vhost keeps the hostname verbatim" \
   "${d}/piler-nginx.conf" "server_name piler-${hostile}.example.com;"
check_file_has "config-site.php keeps the hostnames verbatim" \
   "${d}/config-site.php" "\$config['DB_HOSTNAME'] = 'host-${hostile}';"
check_file_has "SPHINX_HOSTNAME keeps the value verbatim" \
   "${d}/config-site.php" "\$config['SPHINX_HOSTNAME'] = 'search-${hostile}:9306';"

echo "# PATH_PREFIX reaches both the PHP config and the JS asset"

# Has to end up /archive/ on both sides: quoted in the JS, bare in the PHP.
for given in '/archive' 'archive/' '/archive/'; do
   d="$(new_dir)"
   boot "$d" 'piler123' "PATH_PREFIX=${given}"
   check_file_has "PATH_PREFIX=${given} normalizes in config-site.php" \
      "${d}/config-site.php" "\$config['PATH_PREFIX'] = '/archive/';"
   check_file_has "PATH_PREFIX=${given} normalizes in piler.js" \
      "${d}/piler.js" "location.origin + '/archive/',"
   check_file_has "PATH_PREFIX=${given} keeps the JS line prefix" \
      "${d}/piler.js" "base_url: location.origin"
done

d="$(new_dir)"
boot "$d" 'piler123' 'PATH_PREFIX=/'
check_file_has "PATH_PREFIX=/ stays /" \
   "${d}/config-site.php" "\$config['PATH_PREFIX'] = '/';"

d="$(new_dir)"
boot "$d" 'piler123'
check_eq "no PATH_PREFIX leaves the JS asset alone" \
   "    base_url: location.origin + '/'," "$(cat "${d}/piler.js")"
check_eq "no PATH_PREFIX writes no PHP key" \
   "0" "$(grep -cF "PATH_PREFIX" "${d}/config-site.php")"

# The old JS sed needed the quotes passed in; someone may still be doing it.
d="$(new_dir)"
if boot "$d" 'piler123' "PATH_PREFIX='/archive/'" 2> /dev/null; then
   ko "a quoted PATH_PREFIX was accepted"
else
   ok "a quoted PATH_PREFIX is rejected"
fi

d="$(new_dir)"
boot "$d" 'piler123'
: > "${d}/piler.js"
if KEEP_JS=1 boot "$d" 'piler123' 'PATH_PREFIX=/archive' 2> /dev/null; then
   ko "a piler.js without location.origin was accepted"
else
   ok "a piler.js without location.origin is rejected"
fi

echo "# a key missing from the live piler.conf is appended, not fatal"

# sed cannot add a line, which is how RT=1 used to be accepted then dropped on
# ns8-piler, whose template has no rtindex.
for key in mysqlpwd mysqlhost hostid rtindex pidfile mysqlsocket; do
   d="$(new_dir)"
   boot "$d" 'piler123'
   sed -i "/^${key}=/d" "${d}/piler.conf"
   # Explicit, so a refusal is a named failure rather than an errexit abort.
   if boot "$d" 'appended-secret' 2> /dev/null; then
      check_eq "${key} is appended when the live file lacks it" \
         "1" "$(grep -c "^${key}=" "${d}/piler.conf")"
   else
      ko "${key} missing from the live piler.conf refused to start"
   fi
done

# Without a final newline the appended key would join the last line.
d="$(new_dir)"
boot "$d" 'piler123'
sed -i '/^rtindex=/d' "${d}/piler.conf"
printf '%s' "$(cat "${d}/piler.conf")" > "${d}/piler.conf.tmp"
mv "${d}/piler.conf.tmp" "${d}/piler.conf"
boot "$d" 'piler123'
check_eq "rtindex is on its own line after appending to a file with no final newline" \
   "rtindex=1" "$(grep '^rtindex=' "${d}/piler.conf")"

d="$(new_dir)"
boot "$d" 'piler123'
sed -i '/^hostid=/d' "${d}/piler.conf"
boot "$d" 'piler123' 'PILER_HOSTNAME=x&y/z%w.example.com'
check_eq "an appended value keeps sed-special characters" \
   "hostid=x&y/z%w.example.com" "$(grep '^hostid=' "${d}/piler.conf")"

echo "# a key renamed in the shipped template fails loudly instead of silently"

# Not hypothetical: the first version of this work edited `mysqlpassword=`,
# which does not exist. The key is `mysqlpwd=`.
for key in mysqlpwd mysqlhost hostid rtindex pidfile; do
   d="$(new_dir)"
   broken="${WORK}/broken-${key}"
   mkdir -p "$broken"
   cp "${TMPL}"/* "${broken}/"
   sed -i "/^${key}=/d" "${broken}/piler.conf.dist"
   if TMPL="$broken" boot "$d" 'piler123' 2> /dev/null; then
      ko "a shipped template without ${key}= was accepted"
   else
      ok "a shipped template without ${key}= is rejected"
   fi
done

echo
if [[ "$failures" -eq 0 ]]; then
   echo "all checks passed"
else
   echo "${failures} check(s) failed" >&2
   exit 1
fi
