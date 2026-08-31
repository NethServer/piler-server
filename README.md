# piler-server

Rootless container image for [piler](https://github.com/jsuto/piler), the
mail archiving server.

## Contents

- [Why a separate image](#why-a-separate-image)
- [Rootless design](#rootless-design)
- [Repository layout](#repository-layout)
- [Quick start](#quick-start)
- [Build](#build)
- [Run](#run)
- [Release](#release)
- [Debugging](#debugging)
- [CI](#ci)
- [Renovate](#renovate)
- [Attachment text extraction](#attachment-text-extraction)
- [Piler daemon supervision](#piler-daemon-supervision)

## Why a separate image

Available piler images are tagged manually and rebuilt rarely. Renovate
can't keep them current. This image tracks Ubuntu's dated "resolute" (26.04)
base tags directly. A new base image triggers a rebuild.

## Rootless design

The container runs entirely as uid/gid `1000` (`piler`). `CAP_DROP: ALL` is
set, with only `CAP_NET_BIND_SERVICE` added back so nginx/piler can bind
ports 25/80/443 without root. There is no root inside the container, ever.

That constraint shapes the Dockerfile:

- nginx/php-fpm's `user`/`group` directives are deleted. A non-root master
  process can't drop privileges it never had.
- Their pidfiles/sockets live in `/var/piler/run`, not `/run/...` (root-owned
  tmpfs a non-root process can't write subdirectories into).
- nginx/php-fpm access/error logs go to the container's stdout/stderr, like
  every other supervised program.
- `piler`'s postinst creates the `piler` system user. The image pins its
  uid/gid to `1000` so volumes keep stable ownership across rebuilds.

Everything is supervised by `supervisord` (`config/supervisord.conf`), which
starts `piler`, `piler-smtp`, `nginx`, `php-fpm`, `supercronic` (runs
`/etc/piler.cron`), and an `exit-on-fatal` listener that kills supervisord if
any supervised program crash-loops past its retry limit.

### Piler's own config files

These come from upstream [jsuto/piler](https://github.com/jsuto/piler), not
this image. `entrypoint.sh` only fills in environment-specific values:

- `piler.conf` — main config: database connection, hostid, TLS, real-time
  indexing toggle, pidfile location.
- `config-site.php` — web UI config: database connection, decrypt binaries,
  memcached, manticore hostnames.
- `piler-nginx.conf` — the vhost nginx serves piler's web UI from.

The packaged `manticore.conf` is deliberately not one of them. It configures a
local `indexer`/`searchd`, neither of which this image ships or starts, so
nothing would read it. Manticore runs in its own container and takes its config
from there — see [config/manticore.conf](config/manticore.conf), a different
file that happens to share the name.

## Repository layout

- `Dockerfile` — the image: a `fetcher` stage plus a `runtime` stage.
- `entrypoint.sh` — generates the config files above, waits for MySQL,
  creates the schema, hands off to supervisord.
- `config/supervisord.conf` — what supervisord starts and how logs stream.
- `config/exit-on-fatal-listener.py` — the `exit-on-fatal` listener above.
- `config/piler-run.sh` — runs the piler daemon in the foreground for
  supervisord, see below.
- `config/syslog-to-stderr.c` — the `LD_PRELOAD` shim below.
- `build-images.sh` — local build/tag helper, also used by CI.
- `dockerfile-vars.sh` — reads `PILER_VERSION`/`BASE_IMAGE` back out of the
  Dockerfile, shared by `build-images.sh` and `release-tag.sh`.
- `release-tag.sh` — computes, creates, and pushes the release tag.
- `docker-compose.yml` — full stack (mysql, manticore, memcached, piler)
  used to run and validate the image.
- `tests/entrypoint-config-test.sh` — offline tests for the config generation,
  see below.
- `.hadolint.yaml` — Dockerfile lint policy, with the reason for each ignore.
- `.github/workflows/` — CI, see below.

## Quick start

```sh
./build-images.sh
docker compose up
```

## Build

The Dockerfile has two stages:

- `fetcher` — installs `curl`/`ca-certificates`. Resolves piler's amd64 `.deb`
  asset from the GitHub release matching `PILER_VERSION` and the `supercronic`
  amd64 binary, and verifies both against their pinned `sha256` (`PILER_SHA256`
  / `SUPERCRONIC_SHA256`). The image is amd64-only.
- `runtime` — the actual image. It only `COPY --from=fetcher`s the two
  resulting artifacts. The fetch tooling never reaches the final image.

```sh
./build-images.sh
```

Set `ENGINE=docker`, `ENGINE=podman`, or `ENGINE=buildah` to pick the
container engine (auto-detected, prefers podman). Set `REPOBASE`/`IMAGETAG`
to control the image name and extra tag. See `build-images.sh` for details.
This script only builds and tags locally — CI pushes.

`PILER_VERSION` and `BASE_IMAGE` (Dockerfile `ARG`s) are read back by
`dockerfile-vars.sh`. Bumping `PILER_VERSION` is the only manual step to
pick up a new piler release. The `.deb` asset is resolved at build time.

## Run

```sh
docker compose up
```

See `docker-compose.yml` for the full stack: `mysql` (MariaDB), `manticore`
(full-text search, pinned to what piler 1.4.9 was built against),
`memcached`, and `piler` itself.

### Environment variables

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
| `RT` | `1` | Real-time indexing. Must be `1`; any other value aborts the start |
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
| `PILER_USER` | `piler` | Owner of the generated files, set in the Dockerfile |

Notes on four of them.

`PATH_PREFIX` takes a bare path, no quotes: `/archive`, `archive/` and
`/archive/` all become `/archive/`, the form upstream concatenates with relative
asset paths. A quote in the value is rejected.

`MYSQL_PORT` lands in three grammars — `mysqlport`, a `port` line in `.my.cnf`,
and appended to `DB_HOSTNAME` as `host:port`. That last one is not a port field,
piler's PHP building its DSN without one, but PDO parses `host:port`. It is
written even at the default, so the generated files name the port instead of
implying it.

`MANTICORE_PORT` covers both consumers, `sphxport` for the daemon and
`SPHINX_HOSTNAME` for the UI, so they cannot drift. Any port that is not a
number aborts the start rather than leaving a config that never connects.

`PILER_USER` is only worth overriding against an image whose uid/gid layout
differs.

`CONFIG_DIR`, `TMP_CONF_DIR` and `PILER_JS` also exist, for
`tests/entrypoint-config-test.sh` to drive the entrypoint against a throwaway
directory. Not for deployments.

Every value is escaped for the grammar it lands in — sed replacement text, a PHP
literal, a MariaDB option file, an SQL literal — so a generated password needs no
character restriction.

### Volumes

> [!CAUTION]
> `piler_etc` holds `piler.key`, the key the archived mail in `piler_store` is
> encrypted with. **Back up both volumes together, and never delete
> `piler.key`.** A store without its key cannot be decrypted, and there is no
> recovery: a new key does not open old mail.

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

So a changed `MYSQL_PASSWORD` or `MANTICORE_HOSTNAME` takes effect on a restart,
and a hand edit to one of those keys does not survive it. A create-only file is
regenerated by deleting it and restarting — except `piler.key`, see above.

`config-site.php` splits in two. These follow the environment and are replaced
every start, so set them through the variables above:

`DB_HOSTNAME`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `SPHINX_HOSTNAME`,
`SPHINX_HOSTNAME_READONLY`, `$memcached_server`, and `PATH_PREFIX` when set.

These are constants, written only when the file does not already state them, so
a deployment that sets one keeps it:

`RT`, `SPHINX_MAIN_INDEX`, `MEMCACHED_ENABLED`, `DECRYPT_BINARY`,
`DECRYPT_ATTACHMENT_BINARY`, `PILER_BINARY`, `RELOAD_COMMAND`.

Every other key is yours. The same holds for `piler.conf`: a file supplied by a
volume or a downstream module needs to list only what it actually decides.

### Default credentials

Piler ships two built-in accounts, not generated by this image:
`admin@local` / `pilerrocks` (admin) and `auditor@local` / `auditor`
(read-only search). `validate.yml` logs in as both to smoke-test the image.
Change or disable these before exposing an instance beyond a trusted network.
The `MYSQL_PASSWORD` in `docker-compose.yml` (`piler123`) is likewise a demo
value — override it (and the app accounts above) for anything beyond local
testing.

This repository only builds and validates the container image standalone,
via `docker-compose.yml`. It has no orchestration/upgrade logic and no
opinion on where its named volumes live on disk. That's what
[NethServer/ns8-piler](https://github.com/NethServer/ns8-piler) provides:
the NS8 module deploying this image in production. The image itself works
standalone with just `docker compose up`, given the same env vars/volumes.

## Release

A release is a git tag `v<PILER_VERSION>-<BASE_IMAGE_TAG>`, e.g.
`v1.4.9-resolute-20260610`. Pushing that tag is what triggers `release.yml`
— pushing to `main` alone does not create a release.

See the current tag your Dockerfile would produce:

```sh
./release-tag.sh --show
```

Create the tag on HEAD:

```sh
./release-tag.sh --tag
```

Create and push it in one step (triggers `release.yml`):

```sh
./release-tag.sh --tag --push
```

`release-tag.sh` reads `PILER_VERSION`/`BASE_IMAGE` the same way
`build-images.sh` does (via `dockerfile-vars.sh`), so the tag always matches
what the Dockerfile actually builds.

## Debugging

All process output — supervisord's own state transitions, and every
supervised program's stdout/stderr — streams to the container's
stdout/stderr. `docker compose logs piler` / `podman logs <container>` show
everything, no shell needed inside the container.

Useful checks on a stuck or crash-looping container:

- `docker compose ps` / `podman ps` — stuck at `health: starting` past
  `start_period` (15s), or `unhealthy`, means the healthcheck
  (`curl -s smtp://localhost/`) is failing. Check `curl` is present and
  nginx actually started.
- A crash before "supervisord started" in the logs means one of
  `entrypoint.sh`'s startup steps failed — read `entrypoint.sh` for the
  exact sequence. Usually a missing env var or a permission error writing
  into `/etc/piler` (the `piler_etc` volume).
- `safe_sed` (used by `entrypoint.sh` to rewrite config values) needs write
  permission on the target file itself, not just its directory. A config
  file left root-owned by an older, root-run image will fail with
  `Permission denied` after upgrading to this rootless image.
- A few log lines are expected and harmless: nginx/php-fpm noting their
  `user`/`group` directives are ignored (informational); supercronic logging
  `process reaping disabled, not pid 1` (supervisord is pid 1 here and already
  reaps children); and supervisord's `CRIT Server 'unix_http_server' running
  without any HTTP authentication checking` — that control socket is a
  filesystem socket restricted to the piler user (`chmod 0700`), not a network
  listener.

## CI

Four workflows under `.github/workflows/`:

| Workflow | Trigger | Does |
| --- | --- | --- |
| `lint.yml` | every push and PR, forks included | shellcheck, hadolint, and `tests/entrypoint-config-test.sh`. No credentials, no build, under a minute |
| `build.yml` | push to `main`, internal PRs | builds and pushes. Fork PRs are skipped so untrusted code never runs in CI |
| `validate.yml` | `build.yml` completing, or `workflow_dispatch` | starts the full compose stack and exercises it, see below |
| `release.yml` | pushing a `v*` tag | checks the tag matches the Dockerfile, then builds and pushes it with refreshed `latest`/`<base_image_tag>` |

`build.yml` tags `latest` only on the default branch, otherwise a sanitized
branch name; every build also gets an immutable sha tag, which is what
`validate.yml` pins to. A `concurrency` group cancels an older in-flight build
on the same ref.

`validate.yml` logs in as admin and auditor, sends a real mail over SMTP and
checks it is archived and searchable, restarts the stack and checks the mail
survives, checks a restart neither grows nor breaks `config-site.php`, rotates
the database password and checks both the archiver and the UI pick it up, and
forces a service into `FATAL` to verify `exit-on-fatal` brings the container
down. Dispatch it manually to test a branch: `workflow_run` always loads the
workflow file from `main`.

## Renovate

- Ubuntu base image (`FROM`/`BASE_IMAGE` tag): tracked natively by Renovate's
  `docker` datasource, no custom config needed.
- `PILER_VERSION`: tracked via a `customManagers` regex entry against
  upstream piler GitHub releases.
- `SUPERCRONIC_VERSION`: same mechanism against `aptible/supercronic`
  releases.
- Checksums (`PILER_SHA256`, `SUPERCRONIC_SHA256`) are **not** managed by
  Renovate. When a version-bump PR lands, the build fails on the sha256 check
  until the new digest is pasted in by hand — copy it from the asset's sha256
  on the release page (URLs are in the Dockerfile comments next to each ARG).

## Attachment text extraction

Piler extracts searchable text from attachments with external converters, and
the image installs the ones it expects: `catdoc` (legacy `.doc`), `unrtf`,
`poppler-utils` (`pdftotext`), `tnef`.

`catdoc` is kept deliberately, despite [jsuto/piler#484](https://github.com/jsuto/piler/issues/484)
asking for a replacement. It is unmaintained since 2010 with unpatched parser
bugs, and it runs on untrusted attachments — a real concern, not a theoretical
one. But availability is not the problem (`1:0.95-6build1` is in Ubuntu
resolute *and* stonking, `1:0.95-6` in Debian trixie/forky/sid, so no build
break is coming) and there is no reasonable substitute: `antiword` is equally
dead, LibreOffice headless adds hundreds of megabytes, Apache Tika needs a JVM.

So: keep it, and revisit if upstream picks a replacement or a distribution
drops the package.

## Piler daemon supervision

`piler` and `piler-smtp` are ordinary supervisord programs. `-d` is optional for
both, and `piler` writes its pidfile even without it, so foreground mode keeps
`rc.piler reload` (the web UI's "Apply changes" button) working.
`config/piler-run.sh` only wraps `piler` to clear a pidfile left by a SIGKILL —
piler refuses to start when one exists.

`priority` orders them: supervisord starts low-to-high and stops high-to-low, so
`piler` (100) comes up before `piler-smtp` (200) accepts mail, and on the way
down nginx/php-fpm/supercronic (999) go first, then the intake, then the
archiver. `piler-smtp` also gets `startretries=15`, because its listener has no
`SO_REUSEADDR`: after any client connection a respawn takes up to ~60s of
TIME_WAIT before it can rebind port 25 (measured at 68s locally), exiting 1
meanwhile — the default 3 retries would take the container down over a window
that clears itself.

A daemon that dies is restarted; one that crash-loops past `startretries` goes
`FATAL`, and the `exit-on-fatal` listener kills supervisord so the orchestrator
restarts the container clean. `validate.yml` exercises both paths.

### Piler's logs

`piler` and `piler-smtp` log only through `syslog(3)`, and there is no `/dev/log`
in the container — uid 1000 can't create one in the runtime's root-owned `/dev`.
Every line was dropped, so the daemons were the only thing here without logs.

`config/syslog-to-stderr.c` is an `LD_PRELOAD` shim overriding `syslog` and
`__syslog_chk` (the piler binaries are built fortified, so that's the symbol
they actually call) to write to stderr instead. Supervisord then ships those
lines to the container log like nginx's and php-fpm's. It's compiled in its own
build stage, and preloaded for `piler`, `piler-smtp` and `supercronic` only —
never for php-fpm or nginx, which have real log configuration.

Upstream would be the better place to fix this (`LOG_PERROR` when not
daemonising, or a config toggle); drop the shim if that lands.

### Graceful stop

On `SIGTERM`, `config/piler-run.sh` waits for `piler` to empty `/var/piler/tmp`
before stopping it — `piler-smtp` is already down by then, so nothing refills
the spool. It gives up after `PILER_STOP_DRAIN_TIMEOUT` seconds and stops piler
anyway; `PILER_STOP_DRAIN=0` skips the wait entirely. Without this, mail already
accepted sat in the spool until the next start, delayed behind whatever arrived
after it.

The effective window is `min(container stop grace, PILER_STOP_DRAIN_TIMEOUT)`,
and the engine default grace is 10s — far below the 300s default here.
`docker-compose.yml` sets `stop_grace_period: 360s`; anything else running this
image needs the equivalent (`podman stop -t`, or `TimeoutStopSec` on the systemd
unit under NS8), otherwise the container is SIGKILLed mid-drain.
