#!/usr/bin/env bash
# Prints the versions of the tools in this image as JSON. CI compares them with manifest.json.
set -euo pipefail

jq -n \
    --arg sysbench "$(sysbench --version | awk '{print $2}')" \
    --arg 7zip "$(7z | awk '/^7-Zip/{print $2; exit}')" \
    --arg fio "$(fio --version | sed 's/^fio-//')" \
    --arg nginx "$(nginx -v 2>&1 | sed 's|.*/||; s| .*||')" \
    --arg php-fpm "$(php-fpm8.5 -v | awk 'NR==1{print $2}')" \
    --arg wrk "$(wrk -v 2>&1 | awk 'NR==1{sub(/.*\//, "", $2); sub(/-.*/, "", $2); print $2}')" \
    --arg postgresql "$(/usr/lib/postgresql/18/bin/postgres --version | awk '{print $3}')" \
    --arg curl "$(curl --version | awk 'NR==1{print $2}')" \
    --arg bash "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" \
    --arg mtr "$(mtr --version | awk '{print $2}')" \
    '$ARGS.named'
