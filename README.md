# Automated Vulnerability Discovery & Remediation Pipeline

**WordPress + WPScan + GitHub Actions** – DevSecOps Lab 2026

## Repository Structure

```
devsecops-wp-lab/
├── README.md
├── docker/
│   ├── docker-compose.yml          # Local deployment
│   ├── Dockerfile.hardened         # Hardened production image
│   ├── wp-config-placeholder.txt   # Security constants reference
│   └── hardening/
│       ├── php-hardening.ini
│       ├── apache-security.conf
│       ├── wp-config-extra.php
│       └── docker-entrypoint-hardened.sh
├── src/
│   └── notes.txt                   # Lab working notes & findings
├── scans/
│   └── .gitkeep                    # WPScan outputs stored here by CI
└── .github/
    └── workflows/
        └── scan.yml                # Automated pipeline
```

## Quick Start (Local)

```bash
# 1. Deploy WordPress
cd docker
docker-compose up -d

# 2. Open http://localhost:8080 and complete WP setup

# 3. Run WPScan manually
docker run -it --rm wpscanteam/wpscan \
  --url http://host.docker.internal:8080 \
  --enumerate u,vp,vt \
  --force
```

## GitHub Actions Pipeline

The workflow (`.github/workflows/scan.yml`) has three jobs:

| Job | Trigger | What it does |
|-----|---------|--------------|
| `wpscan-vanilla` | push to main | Spins up vanilla WP, runs WPScan, uploads artifact |
| `build-hardened` | after vanilla scan | Builds & pushes hardened image to GHCR + Docker Hub |
| `wpscan-hardened` | after build | Re-scans hardened image, compares results |

### Required Secrets

| Secret | Description |
|--------|-------------|
| `WPSCAN_API_TOKEN` | From wpscan.com (free) |
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |

## Hardening Applied

- Non-root container user (`www-data`)
- OS packages updated; `imagemagick` and `perl` removed
- PHP dangerous functions disabled
- `expose_php = Off`, `display_errors = Off`
- Apache: `ServerTokens Prod`, XML-RPC blocked, security headers
- WordPress: `DISALLOW_FILE_EDIT`, `DISALLOW_FILE_MODS`, debug disabled
- setuid/setgid bits stripped from all binaries
- File permissions locked (`644` files, `755` dirs)

## Docker Hub

Hardened image: `docker pull <your-dockerhub-username>/wordpress-hardened:hardened`
