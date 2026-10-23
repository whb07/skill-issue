#!/usr/bin/env bash
# Builds the test repo in the current directory. The build script runs from
# outside the repo so it doesn't end up committed in it.
set -eu
bash "$(cd "$(dirname "$0")" && pwd)/files/build-repo.sh"
