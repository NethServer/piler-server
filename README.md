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
- `manticore.conf` — full-text search daemon config.
- `piler-nginx.conf` — the vhost nginx serves piler's web UI from.

## Repository layout

- `Dockerfile` — the image: a `fetcher` stage plus a `runtime` stage.
- `entrypoint.sh` — generates the config files above, waits for MySQL,
  creates the schema, hands off to supervisord.
- `config/supervisord.conf` — what supervisord starts and how logs stream.
- `config/exit-on-fatal-listener.py` — the `exit-on-fatal` listener above.
- `config/piler-run.sh` — runs the piler daemon in the foreground for
  supervisord, see below.
- `build-images.sh` — local build/tag helper, also used by CI.
- `dockerfile-vars.sh` — reads `PILER_VERSION`/`BASE_IMAGE` back out of the
  Dockerfile, shared by `build-images.sh` and `release-tag.sh`.
- `release-tag.sh` — computes, creates, and pushes the release tag.
- `docker-compose.yml` — full stack (mysql, manticore, memcached, piler)
  used to run and validate the image.
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

Required (`entrypoint.sh`'s `pre_flight_check` aborts if any is missing):

- `PILER_HOSTNAME` — hostname piler identifies itself as (`hostid` in
  `piler.conf`, also used for the TLS certificate's CN).
- `MYSQL_HOSTNAME`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` —
  database connection.

Optional:

- `RT` (default `1`, and must be `1`) — real-time manticore indexing. This
  image only supports RT mode: manticore runs as a separate container and no
  local `indexer` binary is shipped, so batch indexing (`RT=0`) cannot build
  or rotate indexes. The entrypoint rejects any value other than `1`.
- `PATH_PREFIX` — set if piler's web UI is served behind a reverse-proxy
  path prefix.
- `ADMIN_USER_PASSWORD_HASH` — if set, overwrites the built-in admin
  account's password hash at database init time.
- `MANTICORE_HOSTNAME` (default `manticore`), `MEMCACHED_HOSTNAME` (default
  `memcached`) — override if those services aren't named as in
  `docker-compose.yml`.
- `PILER_STOP_DRAIN` (default `1`), `PILER_STOP_DRAIN_TIMEOUT` (default `300`),
  `PILER_STOP_DRAIN_INTERVAL` (default `2`) — graceful stop, see below.

### Volumes

- `piler_etc` (`/etc/piler`) — generated config (`piler.conf`,
  `config-site.php`, `manticore.conf`, TLS cert/key). `entrypoint.sh` only
  writes a file here if it doesn't already exist, so editing one by hand
  persists across restarts. To force regeneration, delete the corresponding
  file from the volume and restart the container.
- `piler_store` (`/var/piler/store`) — the actual archived mail. Back it up.
- `piler_spool` (`/var/piler/tmp`) — mail accepted by `piler-smtp` and not yet
  archived by `piler`. Transient, not a backup target, but it must be a volume:
  a container recreation with a non-empty spool would otherwise drop that mail.

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

Three workflows, all under `.github/workflows/`:

- `build.yml` — builds and pushes the image on every push to `main` and on
  pull requests from internal branches. Fork PRs are skipped, so untrusted
  code never runs in CI. Tags `latest` only on the default branch, otherwise a
  sanitized branch-name tag; every build also gets an immutable sha tag. A
  `concurrency` group cancels an in-flight older build when a newer commit
  lands on the same ref.
- `validate.yml` — triggered by `build.yml` completing (`workflow_run`), or
  manually (`workflow_dispatch`, useful to test a fix before merging since
  `workflow_run` always loads the workflow file from `main`). Starts the
  full `docker-compose.yml` stack, waits for the healthcheck, logs in as
  admin and auditor, sends a real test email over SMTP, checks it's
  archived and full-text searchable, restarts `mysql`/`piler` and checks the
  archived mail survives, and finally forces a service into `FATAL` to verify
  `exit-on-fatal` brings the container down. It checks out the triggering ref
  with `persist-credentials: false` and least-privilege permissions.
- `release.yml` — triggered by pushing a `v*` git tag (see
  [Release](#release) above). Verifies the tag matches the Dockerfile's
  `PILER_VERSION`/`BASE_IMAGE`, then builds and pushes it alongside
  refreshed `latest`/`<base_image_tag>` tags.

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
