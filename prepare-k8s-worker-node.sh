#!/usr/bin/env bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run this script with sudo or as root." >&2
  exit 1
fi

echo "===> [5/6] Configuring Firewall Rules (UFW)..."
if command -v ufw >/dev/null 2>&1; then
    ufw allow 10250/tcp
    ufw allow 30000:32767/tcp comment '# NodePort range'
else
    echo "UFW is not installed. Skipping firewall rules."
fi
