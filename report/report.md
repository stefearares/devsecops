# Automated Vulnerability Discovery and Remediation Pipeline

**Rares-Bogdan Stefea, May 12, 2026**

## 1. Environment Setup

For the local WordPress deployment I made a `docker-compose.yml` with two services:

- **MySQL 8.0** as the database, with a `mysqladmin ping` healthcheck so the WordPress container only starts once the DB actually responds.
- **WordPress 6.4 (php8.2-apache)** exposed on **port 8080**, also with a healthcheck so I can use `docker compose up --wait` in CI and the workflow only moves on once Apache is up.

I also made an env var of the WordPress image with `${WP_IMAGE:-wordpress:6.4-php8.2-apache}`. This way the same compose file works for both the vanilla scan and the hardened rescan,the workflow just sets `WP_IMAGE` to the hardened image tag before calling `docker compose up`. 

### Why an older WordPress version?

I deliberately pinned the base to `wordpress:6.4` instead of `wordpress:latest`. Two reasons:

1. **real findings to be meaningful.** A scan against the current stable WordPress would mostly come back empty or with non major issues, which makes a vanilla-vs-hardened comparison not fruitful. Pinning a version from early 2024 guarantees WPScan has actual published CVEs to report, so the "before/after" diff (`scans/comparison/comparison.json`) is grounded in real data.
2. **It mirrors reality.** A lot of production WordPress installs run versions that are 1–2 years behind. 

The only one "bad" choice I did make is using `--admin_user=admin` in the `wp core install` step, which is exactly what a lot of real world installs do. 

For the GitHub Actions pipeline I have built the following workflow:
- **Job 1 — vanilla scan:** spin up the compose stack with the default image, wait for readiness, run WPScan with `--format json`, summarize with `jq`, upload artifacts, and tear the stack down with `docker compose down -v`.
- **Job 2 — build hardened image:** build `Dockerfile.hardened` and push it to GHCR + Docker Hub.
- **Job 3 — hardened rescan:** same as Job 1 but with `WP_IMAGE` pointing to the newly built hardened image, plus a `jq` diff between the vanilla and hardened JSONs.

Every job ends with an `if: always()` cleanup step so containers and volumes never leak.


---

## 2. Findings Overview

### Vanilla WordPress Scan Results

WPScan identified the following issues on the basic WordPress 6.4 instance:

#### WordPress Core Vulnerabilities

These are pulled straight out of `scans/vanilla/wpscan-vanilla.json`:

| # | Vulnerability | Severity | CVE | Fixed In |
|---|--------------|----------|-----|----------|
| 1 | Unauthenticated Stored XSS | High | — | 6.5.2 |
| 2 | Contributor+ Stored XSS in HTML API | Medium | — | 6.5.5 |
| 3 | Contributor+ Stored XSS in Template-Part Block | Medium | — | 6.5.5 |
| 4 | Contributor+ Path Traversal in Template-Part Block | Medium | — | 6.5.5 |
| 5 | Author+ DOM Stored XSS | Medium | CVE-2025-58674 | 6.8.3 |
| 6 | Contributor+ Sensitive Data Disclosure | Medium | CVE-2025-58246 | 6.8.3 |

#### Plugin Vulnerabilities

| Plugin | Vulnerability | CVE | Fixed In |
|--------|--------------|-----|----------|
| Akismet | Unauthenticated Stored XSS | CVE-2015-9357 | 3.1.5 |

#### Server Issues

| Issue | Risk |
|-------|------|
| Server header exposes `Apache/2.4.57 (Debian)` | Information disclosure — aids attacker reconnaissance |
| `X-Powered-By: PHP/8.2.17` header exposed | Information disclosure — reveals exact PHP version |
| XML-RPC enabled (`xmlrpc.php`) | Brute-force amplification, DDoS pingback attacks |
| `readme.html` publicly accessible | Reveals exact WordPress version to attackers |
| `wp-cron.php` externally accessible | Potential DDoS vector via cron abuse |
| `admin` username enumerable | Enables targeted brute-force attacks |
| Theme `twentytwentyfour` outdated (v1.0 → v1.4) | Potential unpatched theme vulnerabilities |
| No security headers (CSP, X-Frame-Options, etc.) | Vulnerable to clickjacking, XSS, MIME-sniffing |

### Risk Assessment

The most critical finding is the **Unauthenticated Stored XSS** vulnerability. This allows an unauthenticated attacker to inject malicious JavaScript that executes when any user views the affected content. Combined with the exposed `admin` username an attacker could:

1. **Exploit XSS** to steal admin session cookies
2. **Use XML-RPC** for credential brute forcing against the `admin` user

### How Attackers Could Exploit Them

- **Account Takeover:** Inject a payload that steals the admin's cookie. Once authenticated, the attacker uses the built-in theme editor to inject PHP backdoor code.
- **Brute Force:** The `system.multicall` method allows hundreds of password guesses in a single HTTP request, bypassing traditional rate limits.
- **Information Disclosure Chain:** Knowing the exact Apache, PHP, and WordPress versions lets attackers search for specific CVEs and craft targeted exploits.


---

## 3. Remediation Steps

### 3.1 Patching and Updating

Applied in `docker/Dockerfile.hardened`:

- **WordPress core bumped from 6.4 to 6.8.3:** `FROM wordpress:6.8.3-php8.2-apache`. This closes the 6 core CVEs that the vanilla scan flagged. The new base also ships a newer Akismet, so the `CVE-2015-9357` plugin finding goes away as well.
- **OS updates:** `apt-get update && apt-get upgrade -y` to pull the latest Debian security patches on top of the new base.
- **Removed unnecessary packages:** `imagemagick` removed 
- **WP-CLI installed:** Enables automated WordPress core, plugin, and theme updates.

### 3.2 Hardening Measures

#### PHP Hardening (`hardening/php-hardening.ini`)
- `expose_php = Off` — removes `X-Powered-By` header
- `disable_functions = exec,passthru,shell_exec,system,proc_open,popen,...` — blocks dangerous PHP functions
- `allow_url_fopen = Off`, `allow_url_include = Off` — prevents remote file inclusion
- `display_errors = Off` — prevents error messages leaking to users
- Session security: `cookie_httponly`, `cookie_secure`, `use_strict_mode`, `cookie_samesite`

#### Apache Hardening (`hardening/apache-security.conf`)
- `ServerTokens Prod` — hides Apache version from `Server` header
- `ServerSignature Off` — removes server info from error pages
- `TraceEnable Off` — disables HTTP TRACE 
- `X-Frame-Options: SAMEORIGIN` — prevents hijacking
- `X-XSS-Protection: 1; mode=block` — enables browser XSS filter
- `X-Content-Type-Options: nosniff` — prevents MIME-type checking
- `Content-Security-Policy` — restricts resource loading origins
- `Referrer-Policy: strict-origin-when-cross-origin` — controls referrer information
- `Options -Indexes` — disables directory listing
- `xmlrpc.php` blocked via `Require all denied`
- `readme.html`, `license.txt`, `.htaccess` blocked

#### WordPress Hardening (`hardening/wp-config-extra.php`)
- `DISALLOW_FILE_EDIT = true` — disables the theme code editor in WP admin
- `DISALLOW_FILE_MODS = true` — blocks plugin installation from admin panel
- `WP_DEBUG = false`, `WP_DEBUG_DISPLAY = false` — prevents debug information to leak
- `AUTH_COOKIE_EXPIRATION = 28800` — limits session lifetime to aprx 8 hours

#### Container Hardening (`Dockerfile.hardened`)
- **Runs as non-root** — the entire container,  runs as the unprivileged `www-data` user. If an attacker pops a shell through WordPress they land as `www-data` instead of `root`, which severely limits the blast.
- **Apache rebound to port 8080** — required because non-root processes can't bind to ports below 1024.
- **State dirs pre-owned by `www-data`** — `/var/log/apache2`, `/var/run/apache2`, `/var/lock/apache2`, and `/var/www/html` are all `chown` in the build so Apache and the entrypoint don't need root at runtime.
- Stripped `setuid`/`setgid` from all executables which reduces privilege escalation.
- File permissions changed to `644` for files, `755` for directories.
- WordPress files pre-staged into `/var/www/html` during build so the entrypoint doesn't need root to copy them.

### 3.3 Before/After Scan Evidence


Vanilla scan:

```json
{
  "vanilla":  { "core_vulns": 6, "plugin_vulns": 1, "users": 1, "findings": 4 }
}
```

Expected hardened scan:

```json
{
  "hardened": { "core_vulns": 0, "plugin_vulns": 0, "users": 1, "findings": 1 }
}
```

Per-finding breakdown:

| Finding | Vanilla Scan | Hardened Scan |
|---------|-------------|---------------|
| WordPress core version | `6.4.3` (insecure) | `6.8.3` (current stable) |
| WP core vulns | 6 | **0** (closed by core bump) |
| Akismet plugin vuln (`CVE-2015-9357`) | 1 | **0** (newer Akismet in 6.8.3) |
| `Server` header | `Apache/2.4.57 (Debian)` | `Apache` (version hidden) |
| `X-Powered-By` | `PHP/8.2.17` exposed | **Removed** |
| Security headers | None | `Content-Security-Policy`, `Referrer-Policy`, `X-Frame-Options`, `X-Content-Type-Options` |
| XML-RPC (`xmlrpc.php`) | Enabled and accessible | **Blocked** |
| `readme.html` | Accessible | **Blocked** |
| External `wp-cron.php` | Reported | Still reported (out of scope) |
| User enumeration (`admin`) | Discovered | Discovered |
| Container PID 1 runs as | `root` | **`www-data` (non-root)** |
| Apache listen port | 80 (privileged) | 8080 |

The hardened image now addresses both **patching**  and **defense-in-depth hardening** . 

## 4. Fixed Image Build

### GitHub Repository

**URL:** https://github.com/stefearares/devsecops

Key files:
- `docker/docker-compose.yml` — multi-container stack  with healthchecks and a swappable `WP_IMAGE` so the same file backs both scans
- `docker/Dockerfile.hardened` — hardened image definition
- `docker/hardening/` — PHP, Apache, and WordPress security configurations
- `.github/workflows/scan.yml` — automated scan + build + rescan pipeline 
- `scans/vanilla/wpscan-vanilla.json` — pre-remediation scan 
- `scans/vanilla/wpscan-vanilla-summary.txt` — human-readable summary
- `scans/hardened/wpscan-hardened.json` — post-remediation scan 
- `scans/hardened/wpscan-hardened-summary.txt` — human-readable summary
- `scans/comparison/comparison.json` — vanilla-hardened diff
- `scans/comparison/comparison.txt` — same diff in plain text

### Docker Hub Image

**URL:** https://hub.docker.com/r/stefearares/wordpress-hardened


```bash
docker pull stefearares/wordpress-hardened:hardened
```

---

## 5. Tooling Justification

| Tool | Why |
|------|-----|
| **Docker** | Provides reproducible, isolated environments. Containers ensure the same WordPress configuration runs in CI and production. Immutable images make patching a rebuild-and-replace operation rather than in-place modification. |
| **Docker Compose** | Simplifies multi-container orchestration (WordPress + MySQL) with a single declarative file. Health checks ensure services start in the correct order. |
| **WPScan** | Industry-standard WordPress-specific vulnerability scanner. It checks for known CVEs in core, plugins, and themes using the WPScan Vulnerability Database. Provides actionable output with references to fixes. |
| **GitHub Actions** | Free CI/CD platform tightly integrated with the repository. Supports Docker natively on Ubuntu runners. Workflow artifacts preserve scan results as evidence. `workflow_dispatch` enables manual re-scanning. |
| **GitHub Container Registry (GHCR)** | Stores container images alongside the source code in the same GitHub organization. Supports OCI image format and integrates with GitHub permissions. |
| **Docker Hub** | The most widely-used public container registry. Required deliverable for sharing the hardened image publicly. |
| **WP-CLI** | Command-line interface for WordPress administration. Used to auto-complete WordPress installation in CI (solving the "install mode" problem) and enables scripted core/plugin/theme updates. |
| **`jq`** | Lets the workflow turn WPScan's JSON into a small summary text file and a vanilla-vs-hardened diff without grepping log lines. Makes the comparison reproducible and machine-readable. |

---

## 6. DevSecOps Strategy

### How This Workflow Demonstrates Shift-Left Security

Traditional security testing happens late in the development lifecycle . This pipeline **shifts security left** by integrating vulnerability scanning directly into the CI/CD process:

```
Code Push -> Scan Vanilla Image -> Build Hardened Image -> Re-scan Hardened Image
   |                                                           |
   └────────── Fix vulnerabilities and push again ─────────────┘
```

#### Key Shift-Left Principles Applied

1. **Automated scanning on every push** — Security checks run automatically when code is pushed to `main`, not as a separate manual process. Whoever opened the PR sees vulnerabilities in CI, before the change ever reaches a deployed environment.

2. **Security as Code** — All hardening configurations plus the `docker-compose.yml` and `scan.yml` workflow live in the repo. Security policies are reviewable, auditable, and reproducible.

3. **Immutable infrastructure** — Instead of patching running servers, we rebuild the entire container image with fixes applied and re-scan it. This eliminates configuration drift and ensures every deployment is a known-good state.

4. **Evidence-based remediation, in a machine-readable format** — The pipeline emits WPScan output as **JSON**. That means findings can be diffed programmatically (`scans/comparison/comparison.json`) and the workflow can later be turned into a real gate 

5. **Semi-automated feedback loop** — The workflow supports `workflow_dispatch` for manual re-scanning, enabling a remediation loop:
   - Identify vulnerabilities 
   - Apply fixes 
   - Verify fixes
   
6. **Defense in depth** — Multiple layers of hardening are applied:
   - OS-level (package updates, unnecessary software removed)
   - Web server level (Apache security headers, module configuration)
   - Application level (PHP function restrictions, WordPress security constants)
   - Container level (file permissions, setuid bit removal)


### Continuous Improvement

In a production environment, this pipeline could be extended with:
- **Scheduled scans**  to catch newly disclosed CVEs every x days
- **Slack/email notifications** when new vulnerabilities are found
- **Image signing** with Cosign/Notary for supply chain security

---
