#!/usr/bin/env bash

set -euo pipefail

node_name="$1"
port="$2"
epmd_module="$3"
epmd_ebin_path="$4"
cookie="${5:-expert}"

export EXPERT_PARENT_PORT="$port"

exec iex \
  --erl "-pa ${epmd_ebin_path} -start_epmd false -epmd_module ${epmd_module} -connect_all false" \
  --name "expert-debug-$$@127.0.0.1" \
  --cookie "$cookie" \
  --remsh "$node_name"
