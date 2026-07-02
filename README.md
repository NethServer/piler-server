# piler-docker

Rootless container image for [piler](https://github.com/jsuto/piler), the
mail archiving server.

## Why a separate image

Available piler images are tagged manually and rebuilt rarely, so Renovate
can't keep them current. This image tracks Ubuntu's dated "resolute" (26.04)
base tags directly, so a new base image triggers a rebuild.

## Build

```sh
./build-images.sh
```

Set `ENGINE=docker`, `ENGINE=podman` or `ENGINE=buildah` to pick the
container engine (auto-detected otherwise), `PUSH=1` to push after building,
and `REPOBASE`/`IMAGETAG` to control the image name and tags. See
`build-images.sh` for details; it's also what `.github/workflows/build.yml`
calls in CI.

`PILER_VERSION` (Dockerfile `ARG`) selects the piler release to install; the
actual `.deb` asset (including its build commit hash) is resolved from the
GitHub release at build time, so bumping `PILER_VERSION` is the only manual
step - Renovate does this automatically via the regex manager in
`renovate.json`.

## Run

```sh
docker compose up
```

See `docker-compose.yml` for the required environment variables
(`MYSQL_HOSTNAME`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`,
`PILER_HOSTNAME`, ...).

The container runs entirely as uid/gid `1000` (`piler`), with `CAP_DROP: ALL`
and only `CAP_NET_BIND_SERVICE` added back so nginx/piler can still bind
ports 25/80/443 without running as root.

## Known gap to validate

`rc.piler` has no documented foreground mode. It's started once by
`entrypoint.sh` (it forks and manages its own pidfile), and a supervisord
watchdog program restarts it if its pidfile process dies. Confirm this
behaves correctly under real restart/crash scenarios before relying on it in
production.

## Renovate

- Ubuntu base image (`FROM`/`BASE_IMAGE` tag): tracked natively by Renovate's
  `docker` datasource, no custom config needed.
- `PILER_VERSION`: tracked via a `customManagers` regex entry against
  the upstream piler GitHub releases.
- `SUPERCRONIC_VERSION`: same mechanism against `aptible/supercronic`
  releases. The corresponding `SUPERCRONIC_SHA1SUM_AMD64`/`_ARM64` values
  must be updated by hand from the release's published checksums when that
  PR lands.
