#!/bin/bash
set -euo pipefail
WP_CONFIG="/var/www/html/wp-config.php"
EXTRA="/tmp/wp-config-extra.php"

inject_security_constants() {
    if [ -f "$WP_CONFIG" ] && [ -f "$EXTRA" ]; then
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

exec docker-entrypoint.sh "$@"
