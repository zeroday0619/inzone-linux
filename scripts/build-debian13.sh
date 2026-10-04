#!/bin/sh
# Preserve the Debian 13 entry point while sharing the suite-aware build.
set -eu
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec "$script_directory/build-debian.sh" trixie "$@"
