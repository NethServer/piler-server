#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compute the release tag from the Dockerfile ARGs and create it as a git
# tag on HEAD, so you never type it by hand.

set -o errexit
set -o pipefail
set -o nounset

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./dockerfile-vars.sh

tag="v${piler_version}-${base_image_tag}"

usage() {
    cat <<EOF
Usage: ./release-tag.sh --show|--tag [--push]

  --show   print the release tag computed from the Dockerfile ARGs
           (v<PILER_VERSION>-<BASE_IMAGE_TAG>) and exit
  --tag    create that tag on HEAD
  --push   also push the tag, which triggers release.yml

Current Dockerfile would release as: ${tag}
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

do_show=0
do_tag=0
do_push=0
for arg in "$@"; do
    case "${arg}" in
        --show) do_show=1 ;;
        --tag) do_tag=1 ;;
        --push) do_push=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option '${arg}'" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ "${do_show}" -eq 1 ]]; then
    echo "${tag}"
    exit 0
fi

if [[ "${do_tag}" -ne 1 ]]; then
    echo "--tag is required" >&2
    usage
    exit 1
fi

if git rev-parse "${tag}" >/dev/null 2>&1; then
    echo "Tag '${tag}' already exists" >&2
    exit 1
fi

git tag "${tag}"
echo "Created tag ${tag} on $(git rev-parse --short HEAD)"

if [[ "${do_push}" -eq 1 ]]; then
    git push origin "${tag}"
fi
