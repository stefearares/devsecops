#!/bin/bash
set -euo pipefail

# Wait for upstream entrypoint to populate /var/www/html, then inject security constants.
# We exec the original entrypoint first in a subshell only if wp-config.php already exists;
# otherwise we let the original entrypoint handle first-boot setup.

WP_CONFIG="/var/www/html/wp-config.php"
EXTRA="/tmp/wp-config-extra.php"

inject_security_constants() {
    if [ -f "$WP_CONFIG" ] && [ -f "$EXTRA" ]; then
        # Only inject once (idempotent)
        if ! grep -q "DISALLOW_FILE_EDIT" "$WP_CONFIG"; then
            echo "" >> "$WP_CONFIG"
            cat "$EXTRA" >> "$WP_CONFIG"
            echo "[hardened-entrypoint] Security constants injected into wp-config.php"
        else
            echo "[hardened-entrypoint] Security constants already present, skipping."
        fi
    fi
}

inject_security_constants

# Hand off to the official WordPress entrypoint
exec docker-entrypoint.sh "$@"
