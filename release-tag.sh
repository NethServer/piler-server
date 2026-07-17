#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compute the release tag from the Dockerfile ARGs and create it as a git
# tag on HEAD, so you never type it by hand.

set -o errexit
set -o pipefail
set -o nounset

cd "$(dirname "${BASH_SOURCE[0]}")"

# Tolerate an unparseable Dockerfile here so --help still works; the --show
# and --tag paths validate the values before relying on them.
source ./dockerfile-vars.sh || true

tag="v${piler_version:-}-${base_image_tag:-}"

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

require_vars() {
    if [[ -z "${piler_version:-}" || -z "${base_image_tag:-}" ]]; then
        echo "Could not read PILER_VERSION / BASE_IMAGE from Dockerfile" >&2
        exit 1
    fi
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

if [[ "${do_show}" -eq 1 && ( "${do_tag}" -eq 1 || "${do_push}" -eq 1 ) ]]; then
    echo "--show cannot be combined with --tag or --push" >&2
    exit 1
fi

if [[ "${do_show}" -eq 1 ]]; then
    require_vars
    echo "${tag}"
    exit 0
fi

if [[ "${do_tag}" -ne 1 ]]; then
    echo "--tag is required" >&2
    usage
    exit 1
fi

require_vars

if git rev-parse "${tag}" >/dev/null 2>&1; then
    echo "Tag '${tag}' already exists" >&2
    exit 1
fi

git tag "${tag}"
echo "Created tag ${tag} on $(git rev-parse --short HEAD)"

if [[ "${do_push}" -eq 1 ]]; then
    git push origin "${tag}"
fi
