#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build (never push) the piler-server image, for local/dev use.
#
# Pushing is CI's job, not this script's: the GitHub Actions workflows
# call `docker buildx build --push` directly so a multi-arch manifest can
# be built and pushed atomically. This script only adds NethServer image
# naming on top of a plain `podman build`/`buildah build`/`docker buildx
# build --load`. All actual version pinning lives in the Dockerfile ARGs,
# which are read back here so this script and the Dockerfile never drift
# apart.
#
# Usage:
#   ./build-images.sh                            # build locally, tag only
#   IMAGETAG=1.4.9 ./build-images.sh              # add an extra tag
#   SKIP_DEFAULT_TAGS=1 IMAGETAG=pr-42 ./build-images.sh   # tag only pr-42
#
# Env vars:
#   REPOBASE  - registry + namespace (default: ghcr.io/nethserver)
#   IMAGETAG  - extra tag to apply, in addition to the base-image tag and
#               "latest" (default: unset, i.e. only the two default tags)
#   SKIP_DEFAULT_TAGS - if set to 1, don't tag the base-image tag or
#               "latest" - only IMAGETAG is used (default: 0). For test
#               builds that must not touch the stable tags.
#   ENGINE    - container engine to use: podman, buildah or docker
#               (default: auto-detect, preferring podman)
#   PLATFORMS - comma separated platform list, only used with ENGINE=docker.
#               Since this script always loads the result locally (never
#               pushes), only a single platform is supported here - build
#               a multi-arch manifest via CI instead.
#               (default: host platform)

set -o errexit
set -o pipefail
set -o nounset

cd "$(dirname "${BASH_SOURCE[0]}")"

reponame="piler-server"
repobase="${REPOBASE:-ghcr.io/nethserver}"
platforms="${PLATFORMS:-}"

# Read defaults straight from the Dockerfile so this script cannot drift
# from the image it builds.
base_image_tag=$(grep -oP '^ARG BASE_IMAGE=ubuntu:\K.*' Dockerfile)
piler_version=$(grep -oP '^ARG PILER_VERSION=\K.*' Dockerfile)

image="${repobase}/${reponame}"

tags=()
if [[ "${SKIP_DEFAULT_TAGS:-0}" != "1" ]]; then
    tags+=("${image}:${base_image_tag}" "${image}:latest")
fi
if [[ -n "${IMAGETAG:-}" ]]; then
    tags+=("${image}:${IMAGETAG}")
fi

if [[ "${#tags[@]}" -eq 0 ]]; then
    echo "No tags to build: SKIP_DEFAULT_TAGS=1 was set but IMAGETAG is empty" >&2
    exit 1
fi

echo "Building ${image} (piler ${piler_version}, base ubuntu:${base_image_tag})"

# Pick an engine: prefer an explicit ENGINE, otherwise podman, then buildah,
# and docker only as a last resort (multi-arch buildx support).
engine="${ENGINE:-}"
if [[ -z "${engine}" ]]; then
    if command -v podman >/dev/null 2>&1; then
        engine="podman"
    elif command -v buildah >/dev/null 2>&1; then
        engine="buildah"
    elif command -v docker >/dev/null 2>&1; then
        engine="docker"
    else
        echo "No container engine found (podman, buildah or docker required)" >&2
        exit 1
    fi
fi

tag_args=()
for t in "${tags[@]}"; do
    tag_args+=(--tag "${t}")
done

case "${engine}" in
    docker)
        if [[ "${platforms}" == *,* ]]; then
            echo "ENGINE=docker only supports a single platform here (got '${platforms}') - this script always --load, never --push, and buildx cannot load a multi-arch manifest. Build a multi-arch image via CI instead." >&2
            exit 1
        fi
        build_args=(buildx build --file Dockerfile "${tag_args[@]}" --load)
        if [[ -n "${platforms}" ]]; then
            build_args+=(--platform "${platforms}")
        fi
        docker "${build_args[@]}" .
        ;;
    podman)
        # podman build does one platform at a time; build for the host arch
        # only, which is enough for local testing.
        podman build --file Dockerfile "${tag_args[@]}" .
        ;;
    buildah)
        buildah build --file Dockerfile "${tag_args[@]}" .
        ;;
    *)
        echo "Unknown ENGINE '${engine}' (expected docker, podman or buildah)" >&2
        exit 1
        ;;
esac

images=("${image}")

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf "images=%s\n" "${images[*]}" >> "${GITHUB_OUTPUT}"
fi
