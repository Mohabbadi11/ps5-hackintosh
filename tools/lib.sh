# shellcheck shell=bash
# Shared settings for the tools/*.sh scripts: reads .env from the repo root (copy .env.example to .env and fill it in).
#   PS5_LINUX_HOST  IP of the console while it runs Linux (the one you ssh into)
#   PS5_LINUX_USER  ssh user on the console (default root)
_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$_LIB_ROOT/.env" ]; then set -a; . "$_LIB_ROOT/.env"; set +a; fi
: "${PS5_LINUX_HOST:?PS5_LINUX_HOST is not set. Copy .env.example to .env and put the Linux IP of the console in it}"
PS5_LINUX_USER="${PS5_LINUX_USER:-root}"
PS5="${PS5_LINUX_USER}@${PS5_LINUX_HOST}"
