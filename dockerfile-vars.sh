# SPDX-License-Identifier: GPL-3.0-or-later
#
# Read version info from the Dockerfile ARGs. Source this, don't execute it -
# it sets base_image_tag and piler_version in the caller's shell.

base_image_tag=$(grep -oP -m1 '^ARG BASE_IMAGE=ubuntu:\K.*' Dockerfile)
piler_version=$(grep -oP -m1 '^ARG PILER_VERSION=\K.*' Dockerfile)
