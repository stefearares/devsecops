<?php
/**
 * Extra WordPress security constants injected at container startup.
 * This file is appended to wp-config.php by docker-entrypoint-hardened.sh.
 */

// Disable theme/plugin file editor in WP admin
define( 'DISALLOW_FILE_EDIT', true );

// Block plugin/theme installation via WP admin (images are immutable)
define( 'DISALLOW_FILE_MODS', true );

// Never display errors to end users
define( 'WP_DEBUG',         false );
define( 'WP_DEBUG_DISPLAY', false );
@ini_set( 'display_errors', 0 );

// Allow automatic minor/security core updates
define( 'AUTOMATIC_UPDATER_DISABLED', false );
define( 'WP_AUTO_UPDATE_CORE', 'minor' );

// Lock down authentication cookie lifetime (8 hours)
define( 'AUTH_COOKIE_EXPIRATION', 28800 );
