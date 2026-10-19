#!/usr/bin/env bash
# DESC: Test automated string multiplier
count="${1:-1}"
msg="${2:-ping}"
for ((i=0; i<count; i++)); do
  echo -n "$msg "
done
echo ""
