#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/mount-unix.sh"
mount_main Darwin --unmount "$@"
