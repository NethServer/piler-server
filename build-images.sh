#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build (and optionally push) the piler-server image.
#
# This script only adds NethServer image naming and GitHub Actions output
# contract on top of a plain `podman build`/`buildah build`. All actual
# version pinning lives in the Dockerfile ARGs, which are read back here
# so this script and the Dockerfile never drift apart.
#
# Usage:
#   ./build-images.sh                 # build locally, tag only
#   IMAGETAG=1.4.9 PUSH=1 ./build-images.sh   # build, tag and push
#
# Env vars:
#   REPOBASE  - registry + namespace (default: ghcr.io/nethserver)
#   IMAGETAG  - extra tag to apply, in addition to the base-image tag and
#               "latest" (default: unset, i.e. only the two default tags)
#   PUSH      - if set to 1, push the built image(s) (default: 0)
#   ENGINE    - container engine to use: podman, buildah or docker
#               (default: auto-detect, preferring podman)
#   PLATFORMS - comma separated platform list, only used with ENGINE=docker
#               (default: linux/amd64,linux/arm64)

set -o errexit
set -o pipefail
set -o nounset

cd "$(dirname "${BASH_SOURCE[0]}")"

reponame="piler-server"
repobase="${REPOBASE:-ghcr.io/nethserver}"
push="${PUSH:-0}"
platforms="${PLATFORMS:-linux/amd64,linux/arm64}"

# Read defaults straight from the Dockerfile so this script cannot drift
# from the image it builds.
base_image_tag=$(grep -oP '^ARG BASE_IMAGE=ubuntu:\K.*' Dockerfile)
piler_version=$(grep -oP '^ARG PILER_VERSION=\K.*' Dockerfile)

image="${repobase}/${reponame}"

tags=("${image}:${base_image_tag}" "${image}:latest")
if [[ -n "${IMAGETAG:-}" ]]; then
    tags+=("${image}:${IMAGETAG}")
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
        build_args=(buildx build --file Dockerfile "${tag_args[@]}" --platform "${platforms}")
        if [[ "${push}" == "1" ]]; then
            build_args+=(--push)
        else
            build_args+=(--load)
        fi
        docker "${build_args[@]}" .
        ;;
    podman)
        # podman build does one platform at a time; build for the host arch
        # only, which is enough for local testing.
        podman build --file Dockerfile "${tag_args[@]}" .
        if [[ "${push}" == "1" ]]; then
            for t in "${tags[@]}"; do
                podman push "${t}"
            done
        fi
        ;;
    buildah)
        buildah build --file Dockerfile "${tag_args[@]}" .
        if [[ "${push}" == "1" ]]; then
            for t in "${tags[@]}"; do
                buildah push "${t}" "docker://${t}"
            done
        fi
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
