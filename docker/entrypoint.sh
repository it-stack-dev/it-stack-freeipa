#!/bin/bash
# entrypoint.sh — IT-Stack freeipa container entrypoint
set -euo pipefail

echo "Starting IT-Stack FREEIPA (Module 01)..."

# Source any environment overrides
if [ -f /opt/it-stack/freeipa/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/freeipa/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
