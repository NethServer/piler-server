# piler-server

Rootless container image for [piler](https://github.com/jsuto/piler), the
mail archiving server.

## Why a separate image

Available piler images are tagged manually and rebuilt rarely, so Renovate
can't keep them current. This image tracks Ubuntu's dated "resolute" (26.04)
base tags directly, so a new base image triggers a rebuild.

## Rootless design

The container runs entirely as uid/gid `1000` (`piler`), with `CAP_DROP: ALL`
and only `CAP_NET_BIND_SERVICE` added back so nginx/piler can still bind
ports 25/80/443 without running as root. There is no root inside the
container at any point, which shapes most of the Dockerfile:

- nginx and php-fpm's `user`/`group` directives are deleted (not rewritten)
  from their config files: a non-root master process can't drop privileges
  it never had, so the directives would just be ignored with a startup
  warning.
- Their pidfiles/sockets are relocated from `/run/...` (root-owned tmpfs a
  non-root process can't create subdirectories in) to `/var/piler/run`,
  which is part of the image's own writable layer.
- nginx and php-fpm's access/error logs are symlinked/redirected to the
  container's stdout/stderr, same as every other supervised program, so
  nothing accumulates as unrotated files on the `piler_etc` volume.
- `piler`'s own postinst creates the `piler` system user; the image then
  pins its uid/gid to `1000` so bind-mounted/named volumes keep stable
  ownership across rebuilds and hosts.

Everything inside the container is supervised by `supervisord`
(`config/supervisord.conf`), which starts: `nginx`, `php-fpm`, a
`piler-watchdog` program that restarts `rc.piler` if its pidfile process
dies, `supercronic` (runs `/etc/piler.cron` — the same crontab piler's Debian
package ships, indexer/purge/stats jobs), and a `fatal-exit` event listener
that kills supervisord (pid 1) if any program crash-loops past its retry
limit, so the container actually exits instead of running degraded forever.

### Piler's own config files

These come from upstream [jsuto/piler](https://github.com/jsuto/piler), not
from this image — `entrypoint.sh` only fills in the environment-specific
values:

- `piler.conf` — piler's main config: database connection, hostid, TLS,
  real-time indexing toggle, pidfile location.
- `config-site.php` — the web UI's config: database connection, decrypt
  binaries, memcached, manticore hostnames.
- `manticore.conf` — the full-text search daemon's config: which indexes to
  serve and where its data files live.
- `piler-nginx.conf` — the vhost nginx serves piler's web UI from.

## Repository layout

- `Dockerfile` — the image itself, a `fetcher` stage plus a `runtime` stage
  (see below).
- `entrypoint.sh` — first process run in the container; generates the config
  files above, waits for MySQL, creates the schema, starts `rc.piler`, then
  hands off to supervisord.
- `config/supervisord.conf` — what supervisord starts and how each program's
  logs are streamed to stdout/stderr.
- `config/fatal-exit-listener.py` — the `fatal-exit` event listener mentioned
  above.
- `build-images.sh` — local build/tag helper, also used by CI.
- `dockerfile-vars.sh` — reads `PILER_VERSION`/`BASE_IMAGE` back out of the
  Dockerfile so `build-images.sh` and `release-tag.sh` can't drift apart.
- `release-tag.sh` — computes and creates the `v<piler_version>-<base_image_tag>`
  release tag.
- `docker-compose.yml` — the full stack (mysql, manticore, memcached, piler)
  used to run and validate the image.
- `.github/workflows/` — CI, see below.

## Build

The Dockerfile has two stages:

- `fetcher` — installs `curl`/`ca-certificates`, resolves piler's `.deb`
  asset from the GitHub release matching `PILER_VERSION` (the filename embeds
  a build commit hash that isn't tracked as an ARG), downloads it, and
  downloads/verifies the `supercronic` binary against its published SHA1
  checksum.
- `runtime` — the actual image. It only `COPY --from=fetcher`s the two
  resulting artifacts (`piler.deb`, `supercronic`) — the fetch tooling itself
  never reaches the final image.

```sh
./build-images.sh
```

Set `ENGINE=docker`, `ENGINE=podman` or `ENGINE=buildah` to pick the
container engine (auto-detected otherwise, preferring podman), and
`REPOBASE`/`IMAGETAG` to control the image name and extra tag. See
`build-images.sh` for details. This script only builds and tags locally —
CI is what actually pushes.

`PILER_VERSION` and `BASE_IMAGE` (Dockerfile `ARG`s) are read back by
`dockerfile-vars.sh`, shared by `build-images.sh` and `release-tag.sh` so
the two scripts and the Dockerfile can't drift apart. Bumping
`PILER_VERSION` is the only manual step to pick up a new piler release; the
actual `.deb` asset (including its build commit hash) is resolved from the
GitHub release at build time.

## Run

```sh
docker compose up
```

See `docker-compose.yml` for the full stack: `mysql` (MariaDB), `manticore`
(full-text search, version pinned to what piler 1.4.9 was built against),
`memcached`, and `piler` itself.

### Environment variables

Required (`entrypoint.sh`'s `pre_flight_check` aborts if any is missing):

- `PILER_HOSTNAME` — hostname piler identifies itself as (`hostid` in
  `piler.conf`, also used to generate the TLS certificate's CN).
- `MYSQL_HOSTNAME`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` —
  database connection.

Optional:

- `RT` (default `0`) — enable manticore real-time indexing instead of batch.
- `PATH_PREFIX` — set if piler's web UI is served behind a reverse-proxy
  path prefix.
- `ADMIN_USER_PASSWORD_HASH` — if set, overwrites the built-in admin
  account's password hash at database init time.
- `MANTICORE_HOSTNAME` (default `manticore`), `MEMCACHED_HOSTNAME` (default
  `memcached`) — override if those services aren't named as in
  `docker-compose.yml`.

### Volumes

- `piler_etc` (`/etc/piler`) — generated config (`piler.conf`,
  `config-site.php`, `manticore.conf`, TLS cert/key). `fix_configs()` in
  `entrypoint.sh` only writes a file here if it doesn't already exist, so
  editing one by hand persists across restarts. To force regeneration
  (e.g. after changing an env var that's only applied on first write),
  delete the corresponding file from the volume and restart the container.
- `piler_store` (`/var/piler/store`) — the actual archived mail. This is the
  data that matters; back it up.

### Default credentials

Piler ships two built-in accounts, not generated by this image:
`admin@local` / `pilerrocks` (admin) and `auditor@local` / `auditor`
(read-only search). `validate.yml` logs in as both to smoke-test the image.
Change or disable these before exposing an instance beyond a trusted network.

This repository only builds and validates the container image standalone,
via `docker-compose.yml`. It has no orchestration/upgrade logic and no
opinion on where its named volumes live on disk — that's what
[NethServer/ns8-piler](https://github.com/NethServer/ns8-piler) provides:
the actual NS8 module deploying this image in production, wiring its
volumes to NS8-managed storage and generating its config through NS8's own
tooling. In theory nothing here is NS8-specific: the image works standalone
with just `docker compose up`, as long as you provide the same environment
variables and volumes NS8 does.

## Debugging

All process output — supervisord's own program state transitions, and each
supervised program's stdout/stderr (nginx, php-fpm, piler's cron jobs via
supercronic) — is streamed to the container's stdout/stderr, so
`docker compose logs piler` / `podman logs <container>` (and journald, if the
container is run as a systemd unit) show everything without needing a shell
inside the container.

Useful things to check on a stuck or crash-looping container:

- `docker compose ps` / `podman ps` — a container stuck at `health: starting`
  past `start_period` (15s) or reporting `unhealthy` means the healthcheck
  (`curl -s smtp://localhost/`) itself is failing; check `curl` is present
  in the runtime image and that nginx actually started.
- `entrypoint.sh` runs `pre_flight_check`, `fix_configs`,
  `create_my_cnf_files`, `init_database`, then `start_piler` before handing
  off to supervisord — a crash before "supervisord started" in the logs
  means one of those steps failed, usually a missing env var or a
  permission error writing into `/etc/piler` (the `piler_etc` volume).
- `entrypoint.sh` only writes `piler.conf`/`config-site.php`/etc. once (skips
  the write if the file already exists), but always rewrites their
  variable values in place via `safe_sed`. `safe_sed` needs write
  permission on the target file itself, not just its directory — a
  config file left root-owned by an older, root-run image will make this
  fail with `Permission denied` after an upgrade to this rootless image.
- Two warnings that are expected and harmless: nginx/php-fpm logging that
  their `user`/`group` directives are ignored (informational only, kept out
  of the image; see above) is fixed already in this image — if you still
  see them, check you're running the version that dropped those directives.
  Supercronic logging `process reaping disabled, not pid 1` is expected:
  supervisord is pid 1 in this container and already reaps children,
  supercronic just always warns when it isn't pid 1 itself.

## CI

Three workflows, all under `.github/workflows/`:

- `build.yml` — builds and pushes the image on every push to `main` and on
  pull requests (tags: `latest` + `<base_image_tag>` on `main`, a
  branch-name tag plus an immutable sha tag on pull requests).
- `validate.yml` — triggered by `build.yml` completing (`workflow_run`) or
  manually (`workflow_dispatch`, useful to test a fix before merging since
  `workflow_run` always loads the workflow file from `main`, never from the
  triggering branch). Starts the full `docker-compose.yml` stack, waits for
  the healthcheck, logs in as admin and as auditor, sends a real test email
  over SMTP, checks it's archived and full-text searchable, then restarts
  `mysql`/`piler` and checks the archived mail survives.
- `release.yml` — triggered by pushing a `v*` git tag. Verifies the tag
  matches the Dockerfile's `PILER_VERSION`/`BASE_IMAGE` (see
  `release-tag.sh` to create/push that tag correctly), then builds and
  pushes it alongside refreshed `latest`/`<base_image_tag>` tags.

## Renovate

- Ubuntu base image (`FROM`/`BASE_IMAGE` tag): tracked natively by Renovate's
  `docker` datasource, no custom config needed.
- `PILER_VERSION`: tracked via a `customManagers` regex entry against
  the upstream piler GitHub releases.
- `SUPERCRONIC_VERSION`: same mechanism against `aptible/supercronic`
  releases. The corresponding `SUPERCRONIC_SHA1SUM_AMD64`/`_ARM64` values
  must be updated by hand from the release's published checksums when that
  PR lands.

## Known gap to validate

`rc.piler` has no documented foreground mode. It's started once by
`entrypoint.sh` (it forks and manages its own pidfile), and a supervisord
watchdog program restarts it if its pidfile process dies. Confirm this
behaves correctly under real restart/crash scenarios before relying on it in
production.
