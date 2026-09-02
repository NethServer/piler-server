# piler-server

Rootless container image for [piler](https://github.com/jsuto/piler), the
mail archiving server. Available piler images are tagged manually and rebuilt
rarely; this one tracks Ubuntu's dated "resolute" (26.04) base tags, so a new
base image triggers a rebuild.

## Rootless design

The container runs entirely as uid/gid `1000` (`piler`), with `CAP_DROP: ALL`
and only `CAP_NET_BIND_SERVICE` added back so nginx/piler can bind ports
25/80/443. There is no root inside the container, ever.

That constraint shapes the Dockerfile:

- nginx/php-fpm's `user`/`group` directives are deleted. A non-root master
  can't drop privileges it never had.
- Their pidfiles and sockets live in `/var/piler/run`, not `/run/...`, a
  root-owned tmpfs a non-root process can't write subdirectories into.
- nginx/php-fpm logs go to stdout/stderr, like every supervised program.
- `piler`'s postinst creates the `piler` user; the image pins its uid/gid to
  `1000` so volumes keep stable ownership across rebuilds.

`supervisord` (`config/supervisord.conf`) starts `piler`, `piler-smtp`,
`nginx`, `php-fpm`, `supercronic` (running `/etc/piler.cron`), and an
`exit-on-fatal` listener that kills supervisord if a program crash-loops past
its retry limit.

### Piler's own config files

These come from upstream, not this image. `entrypoint.sh` only fills in
environment-specific values:

- `piler.conf` — database connection, hostid, TLS, real-time indexing, pidfile.
- `config-site.php` — web UI: database, decrypt binaries, memcached, manticore.
- `piler-nginx.conf` — the vhost serving the web UI.

The packaged `manticore.conf` is deliberately not one of them: it configures a
local `indexer`/`searchd`, neither of which this image ships, so nothing would
read it. Manticore runs in its own container with its own config — see
[config/manticore.conf](config/manticore.conf), a different file that happens
to share the name.

## Repository layout

Only the files whose purpose is not obvious from the name:

- `entrypoint.sh` — generates the config files, waits for MySQL, creates the
  schema, hands off to supervisord.
- `config/piler-run.sh` — runs the piler daemon in the foreground, see below.
- `config/syslog-to-stderr.c` — the `LD_PRELOAD` shim, see below.
- `config/exit-on-fatal-listener.py` — the `exit-on-fatal` listener.
- `dockerfile-vars.sh` — reads `PILER_VERSION`/`BASE_IMAGE` back out of the
  Dockerfile, shared by `build-images.sh` and `release-tag.sh`.
- `release-tag.sh` — computes, creates and pushes the release tag.
- `.hadolint.yaml` — Dockerfile lint policy, with the reason for each ignore.

## Quick start

Pulls the published image, no build needed:

```sh
cp .env.example .env    # edit the hostname and the database password
docker compose up -d
```

The stack answers on `http://localhost/`; log in with the built-in
`admin@local` (see [Default credentials](#default-credentials)).
`docker compose pull` picks up a newer `latest`.

`.env` is optional — the stack starts on the defaults without it — but
`MYSQL_PASSWORD` and `PILER_HOSTNAME` are both read once, at the first start:
MariaDB only applies the password while initialising its data directory, and
mail is archived under the hostname. Changing either later means
`docker compose down -v`, which destroys the archive. `.env.example`
documents every knob it exposes, including the host ports to move if they are
already taken on your machine.

To run your own build instead, `./build-images.sh` tags
`ghcr.io/nethserver/piler-server:latest` locally and `docker compose up -d`
uses that local tag without pulling.

## Build

Two stages. `fetcher` resolves piler's amd64 `.deb` from the GitHub release
matching `PILER_VERSION`, plus the `supercronic` binary, and verifies both
against their pinned `sha256`. `runtime` only `COPY --from=fetcher`s those two
artifacts, so the fetch tooling never reaches the final image. amd64 only.

Set `ENGINE=docker|podman|buildah` to pick the engine (auto-detected, prefers
podman), and `REPOBASE`/`IMAGETAG` for the image name and extra tag. This
script only builds and tags locally — CI pushes.

Bumping `PILER_VERSION` is the only manual step to pick up a new piler
release; the `.deb` asset is resolved at build time.

## Run

```sh
docker compose up -d
```

`docker-compose.yml` has no `build:` section on purpose: it only ever runs an
image, pulled or locally built, so `up` can never silently replace a published
tag with the working tree. Point `PILER_IMAGE` at another tag to test it.

`docker-compose.yml` has the full stack: `mysql` (MariaDB), `manticore`
(pinned to what piler 1.4.9 was built against), `memcached`, and `piler`.

### Environment variables

`docker-compose.yml` sets every one of these to the default shown, reading it
from `.env` first. `.env.example` lists them all with the traps spelled out;
copy it rather than editing the compose file.

Required — `pre_flight_check` aborts the start if any is missing:

| Variable | Lands in |
| --- | --- |
| `PILER_HOSTNAME` | `hostid` in `piler.conf`, the nginx `server_name`, the web UI's site name |
| `MYSQL_HOSTNAME` | `mysqlhost`, `.my.cnf`, `DB_HOSTNAME` |
| `MYSQL_DATABASE` | `mysqldb`, `DB_DATABASE` |
| `MYSQL_USER` | `mysqluser`, `.my.cnf`, `DB_USERNAME` |
| `MYSQL_PASSWORD` | `mysqlpwd`, `.my.cnf`, `DB_PASSWORD` |

`PILER_HOSTNAME` is not the self-signed certificate's CN, which is a fixed
placeholder.

Optional:

| Variable | Default | What it does |
| --- | --- | --- |
| `PATH_PREFIX` | *unset* | Path prefix when the UI is behind a reverse proxy |
| `ADMIN_USER_PASSWORD_HASH` | *unset* | Overwrites the built-in admin's hash at schema creation |
| `MYSQL_PORT` | `3306` | Database port — MariaDB's own default |
| `MANTICORE_HOSTNAME` | `manticore` | Manticore host |
| `MANTICORE_PORT` | `9306` | Manticore's SQL port — its own default |
| `MANTICORE_PORT_READONLY` | `9307` | Manticore's `mysql_readonly` port — piler's convention |
| `MEMCACHED_HOSTNAME` | `memcached` | memcached host |
| `MEMCACHED_PORT` | `11211` | memcached port — its own default |
| `MYSQL_WAIT_MAX_ATTEMPTS` | `60` | 5-second probes before the start gives up on the database |
| `PILER_STOP_DRAIN` | `1` | Drain the spool on a graceful stop, see below |
| `PILER_STOP_DRAIN_TIMEOUT` | `300` | Seconds to keep draining |
| `PILER_STOP_DRAIN_INTERVAL` | `2` | Seconds between spool checks |
| `PILER_USER` | `piler` | Owner of the generated files — must match the image's uid and the compose `user:`, so the stack never passes it |

Read by compose itself, so they never reach a container:

| Variable | Default | What it does |
| --- | --- | --- |
| `PILER_IMAGE` | `ghcr.io/nethserver/piler-server:latest` | Image the `piler` service runs |
| `HOST_SMTP_PORT` | `25` | Host side of the published SMTP port |
| `HOST_HTTP_PORT` | `80` | Host side of the published HTTP port |

`MANTICORE_PORT` and `MANTICORE_PORT_READONLY` only tell piler where to
connect: manticore's own listeners live in `config/manticore.conf`, which the
entrypoint never touches, so either has to be changed in both places.
`MYSQL_PORT` and `MEMCACHED_PORT` do move the server, both containers take
theirs from the same variable.

There is no `RT` variable to set: with no `indexer` in the image, real-time
mode is the only mode, and any other value aborts the start.

`PATH_PREFIX` takes a bare path, no quotes — `/archive`, `archive/` and
`/archive/` all become `/archive/`. It is not enough on its own: `SITE_URL`,
`BRANDING_LOGO`, `BRANDING_FAVICON` and `SITE_LOGO_LG` stay at the root and the
entrypoint sets none of them. `SITE_URL` is the one that bites — the post-login
redirect is built from it, so a stale value sends the browser out of the prefix.

`MYSQL_PORT` lands in three grammars: `mysqlport`, a `port` line in `.my.cnf`,
and appended to `DB_HOSTNAME` as `host:port`. The last is not a port field, but
PDO parses it. An IPv6 literal is bracketed there, `[::1]:3306`, the only form
PDO accepts; `piler.conf` and `.my.cnf` keep host and port apart and take it
bare.

`MANTICORE_PORT` covers both consumers, `sphxport` for the daemon and
`SPHINX_HOSTNAME` for the UI. These variables are the only way to move
manticore: the daemon's coordinates live in `piler.conf`, which no edit of
`config-site.php` reaches. Setting `SPHINX_HOSTNAME` by hand would move the UI
alone, searching one index while the daemon writes to another. They say where to
*reach* manticore, not where it listens — change
[config/manticore.conf](config/manticore.conf)'s `listen` lines and these have
to follow.

Ports outside 1-65535 are rejected, and no value may contain a newline,
carriage return or tab — a newline aborts a sed mid-file, and escaping eats a
trailing one differently per destination. Spaces and printable characters are
fine: every value is escaped for the grammar it lands in (sed replacement text,
PHP literal, MariaDB option file, SQL literal), so a generated password needs no
character restriction.

`CONFIG_DIR`, `TMP_CONF_DIR` and `PILER_JS` exist for
`tests/entrypoint-config-test.sh` to drive the entrypoint against a throwaway
directory. Not for deployments.

### Volumes

> [!CAUTION]
> `piler_etc` holds `piler.key`, the key the archived mail in `piler_store` is
> encrypted with. **Back up both volumes together, and never delete
> `piler.key`.** A store without its key cannot be decrypted, and a new key
> does not open old mail.

| Volume | Holds | Back up |
| --- | --- | --- |
| `piler_etc` (`/etc/piler`) | `piler.key`, the TLS pair, and the generated `piler.conf`, `config-site.php`, `piler-nginx.conf`, `.my.cnf` | yes, with `piler_store` |
| `piler_store` (`/var/piler/store`) | the archived mail, encrypted | yes |
| `piler_spool` (`/var/piler/tmp`) | mail accepted by `piler-smtp`, not yet archived | no — transient, but it must be a volume or a container recreation drops it |

#### What the entrypoint writes

| File | On every start |
| --- | --- |
| `piler.conf` | sets the connection and daemon keys from the environment, appending a line the file does not carry; every other key is left as found |
| `config-site.php` | rewrites the block below the `# generated by entrypoint` marker; above it is yours |
| `.my.cnf` | rewritten whole |
| `piler-nginx.conf` | rewritten if absent, or if it has no `listen` directive |
| `piler.key`, `piler.pem` | created only if absent |

So a changed `MYSQL_PASSWORD` takes effect on a restart, and a hand edit to one
of those keys does not survive it. A create-only file is regenerated by deleting
it and restarting — except `piler.key`.

`config-site.php` splits in two. Replaced every start, so set them through the
variables above: `DB_HOSTNAME`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`,
`SPHINX_HOSTNAME`, `SPHINX_HOSTNAME_READONLY`, `$memcached_server`, `RT`, and
`PATH_PREFIX` when set.

Written only when the file does not already state them, so a deployment that
sets one keeps it: `SPHINX_MAIN_INDEX`, `MEMCACHED_ENABLED`, `DECRYPT_BINARY`,
`DECRYPT_ATTACHMENT_BINARY`, `PILER_BINARY`, `RELOAD_COMMAND`.

`RT` is in the first list because it is a constraint, not a preference.

`SPHINX_MAIN_INDEX` names the index the UI searches; the daemon reads that name
from `sphxdb`, and Manticore defines it in its own config. Rename in all three
or it fails silently — a mismatch empties search, and an index Manticore does
not define makes piler accept mail over SMTP and never archive it.

Every other key is yours. The same holds for `piler.conf`: a file supplied by a
volume or a downstream module needs to list only what it actually decides.

### Default credentials

Piler ships two built-in accounts, not generated here: `admin@local` /
`pilerrocks` and `auditor@local` / `auditor` (read-only search). The
`MYSQL_PASSWORD` default is likewise a demo value. Change all three before
exposing an instance beyond a trusted network.

`admin@local`'s password can be replaced at the first start with
`ADMIN_USER_PASSWORD_HASH` in `.env`; `auditor@local` has no such hook and has
to be changed from the web UI. Both are only worth doing on a stack that has
not been initialised yet, since the hash is written when the schema is
created.

This repository builds and validates the image standalone, with no
orchestration or upgrade logic. That is what
[NethServer/ns8-piler](https://github.com/NethServer/ns8-piler) provides.

## Release

A release is a git tag `v<PILER_VERSION>-<BASE_IMAGE_TAG>`, e.g.
`v1.4.9-resolute-20260610`. Pushing that tag triggers `release.yml`; pushing to
`main` does not.

```sh
./release-tag.sh --show          # the tag your Dockerfile would produce
./release-tag.sh --tag           # create it on HEAD
./release-tag.sh --tag --push    # create and push, triggering release.yml
```

`release-tag.sh` reads `PILER_VERSION`/`BASE_IMAGE` the same way
`build-images.sh` does, so the tag always matches what the Dockerfile builds.

## Debugging

Everything streams to the container's stdout/stderr — supervisord's state
transitions and every supervised program's output. `docker compose logs piler`
shows it all, no shell needed inside.

On a stuck or crash-looping container:

- Stuck at `health: starting` past the 15s `start_period`, or `unhealthy`: the
  healthcheck (`curl -s smtp://localhost/`) is failing. Check nginx started.
- A crash before "supervisord started": an `entrypoint.sh` step failed, usually
  a missing env var or a permission error writing into `/etc/piler`.
- `Permission denied` from `safe_sed`: it needs write permission on the target
  file itself, not just its directory. A config file left root-owned by an
  older, root-run image fails here.

Expected and harmless: nginx/php-fpm noting their `user`/`group` directives are
ignored; supercronic's `process reaping disabled, not pid 1` (supervisord is pid
1 and already reaps); and supervisord's `CRIT Server 'unix_http_server' running
without any HTTP authentication checking` — that control socket is a filesystem
socket restricted to the piler user (`chmod 0700`), not a network listener.

## CI

| Workflow | Trigger | Does |
| --- | --- | --- |
| `lint.yml` | every push and PR, forks included | shellcheck, hadolint, and `tests/entrypoint-config-test.sh`. No credentials, no build, under a minute |
| `build.yml` | push to `main`, internal PRs | builds and pushes. Fork PRs are skipped so untrusted code never runs in CI |
| `validate.yml` | `build.yml` completing, or `workflow_dispatch` | starts the full compose stack and exercises it |
| `release.yml` | pushing a `v*` tag | checks the tag matches the Dockerfile, then builds and pushes it with refreshed `latest`/`<base_image_tag>` |

`build.yml` tags `latest` only on the default branch, otherwise a sanitized
branch name; every build also gets an immutable sha tag, which is what
`validate.yml` pins to.

`validate.yml` logs in as admin and auditor, sends a real mail and checks it is
archived and searchable, restarts the stack and checks the mail survives and
`config-site.php` neither grows nor breaks, rotates the database password and
checks both the archiver and the UI pick it up, drains the spool, and forces a
service into `FATAL` to verify `exit-on-fatal` brings the container down.
Dispatch it manually to test a branch: `workflow_run` always loads the workflow
file from `main`.

## Renovate

- Ubuntu base image: tracked natively by Renovate's `docker` datasource.
- `PILER_VERSION` and `SUPERCRONIC_VERSION`: `customManagers` regex entries
  against their upstream GitHub releases.
- `docker-compose.yml`'s mariadb and memcached tags are series tags
  (`11.4`, `1.6-alpine`), so Renovate has no patch to bump and a
  `docker compose pull` picks the fixes up on its own. Only manticore is an
  exact patch, since upstream publishes no series tag for it.
- Checksums (`PILER_SHA256`, `SUPERCRONIC_SHA256`) are **not** managed by
  Renovate. A version-bump PR fails the build on the sha256 check until the new
  digest is pasted in by hand — copy it from the release page (URLs are in the
  Dockerfile comments next to each ARG).

## Attachment text extraction

Piler extracts searchable text from attachments with external converters, and
the image installs the ones it expects: `catdoc` (legacy `.doc`), `unrtf`,
`poppler-utils` (`pdftotext`), `tnef`.

`catdoc` is kept deliberately, despite
[jsuto/piler#484](https://github.com/jsuto/piler/issues/484) asking for a
replacement: it is unmaintained since 2010 and runs on untrusted attachments,
but there is no reasonable substitute (`antiword` is equally dead, LibreOffice
headless adds hundreds of megabytes, Tika needs a JVM) and the package is in
current Ubuntu and Debian, so no build break is coming. Revisit if upstream
picks a replacement or a distribution drops it.

## Piler daemon supervision

`piler` and `piler-smtp` are ordinary supervisord programs. `-d` is optional for
both, and `piler` writes its pidfile even without it, so foreground mode keeps
`rc.piler reload` (the UI's "Apply changes") working. `config/piler-run.sh` only
wraps `piler` to clear a pidfile left by a SIGKILL, which piler refuses to start
over.

`priority` orders them: supervisord starts low-to-high and stops high-to-low, so
`piler` (100) comes up before `piler-smtp` (200) accepts mail, and on the way
down nginx/php-fpm/supercronic (999) go first, then the intake, then the
archiver.

`piler-smtp` gets `startretries=15` because its listener has no `SO_REUSEADDR`:
after any client connection a respawn waits out up to ~60s of TIME_WAIT before
it can rebind port 25 (68s measured locally), exiting 1 meanwhile. The default 3
retries would take the container down over a window that clears itself.

A daemon that dies is restarted; one that crash-loops past `startretries` goes
`FATAL`, and `exit-on-fatal` kills supervisord so the orchestrator restarts the
container clean.

### Piler's logs

`piler` and `piler-smtp` log only through `syslog(3)`, and there is no
`/dev/log` in the container — uid 1000 can't create one in the root-owned
`/dev`. Every line was dropped, so the daemons were the only thing here without
logs.

`config/syslog-to-stderr.c` is an `LD_PRELOAD` shim overriding `syslog` and
`__syslog_chk` (the binaries are built fortified, so that is the symbol they
call) to write to stderr, which supervisord then ships to the container log. It
is preloaded for `piler`, `piler-smtp` and `supercronic` only, never for
php-fpm or nginx, which have real log configuration.

Upstream would be the better place to fix this (`LOG_PERROR` when not
daemonising); drop the shim if that lands.

### Graceful stop

On `SIGTERM`, `config/piler-run.sh` waits for `piler` to empty `/var/piler/tmp`
before stopping it — `piler-smtp` is already down, so nothing refills the spool.
It gives up after `PILER_STOP_DRAIN_TIMEOUT` seconds; `PILER_STOP_DRAIN=0` skips
the wait. Without it, accepted mail sits in the spool until the next start.

The effective window is `min(container stop grace, PILER_STOP_DRAIN_TIMEOUT)`,
and the engine default grace is 10s, far below the 300s default here.
`docker-compose.yml` sets `stop_grace_period: 360s`; anything else running this
image needs the equivalent (`podman stop -t`, or `TimeoutStopSec` on a systemd
unit), otherwise the container is SIGKILLed mid-drain.
