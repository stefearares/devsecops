# Automated Vulnerability Discovery & Remediation Pipeline

**WordPress + WPScan + GitHub Actions**

**Author:** Rares Stefea  
**Date:** May 12, 2026  
**Course:** DevSecOps Lab 2026

---

## 1. Environment Setup

### Steps Taken

1. **Local WordPress deployment** — Created a `docker-compose.yml` defining two services:
   - **MySQL 8.0** database container with health checks
   - **WordPress 6.4 (PHP 8.2 + Apache)** container linked to the database, exposed on port 8080

2. **GitHub repository** — Initialized a Git repository with a structured layout:
   ```
   docker/          – docker-compose.yml, Dockerfile.hardened, hardening configs
   .github/workflows/ – scan.yml (CI/CD pipeline)
   scans/           – WPScan output artifacts
   src/             – Working notes
   ```

3. **GitHub Actions pipeline** — Built a 3-job workflow:
   - Job 1: Spin up vanilla WordPress and run WPScan
   - Job 2: Build and push the hardened Docker image
   - Job 3: Re-scan the hardened image to verify fixes

4. **Secrets configuration** — Added three GitHub repository secrets:
   - `WPSCAN_API_TOKEN` — for WPScan vulnerability database access
   - `DOCKERHUB_USERNAME` — Docker Hub credentials
   - `DOCKERHUB_TOKEN` — Docker Hub access token

### Challenges Encountered

| Challenge | Solution |
|-----------|----------|
| `a2enmod`/`a2dismod` not found during Docker build (exit code 127) | These are Perl scripts; `apt-get remove perl` was removing them. Kept perl installed and used full paths. |
| `apt-get autoremove` removing Apache utilities | Removed the `autoremove` step to avoid unintended dependency removal. |
| GHCR push denied ("installation not allowed to Create organization package") | Fixed by updating repository workflow permissions to "Read and write" under Settings → Actions → General. |
| WPScan aborting with "database file is missing" | Removed the `--no-update` flag so WPScan downloads its vulnerability database before scanning. |
| WPScan reporting "Website is in install mode" | Added a `wp core install` step via WP-CLI to auto-complete WordPress setup before scanning. |
| Node.js 20 deprecation warnings in GitHub Actions | Non-blocking warnings; actions still function correctly until June 2026 deadline. |

---

## 2. Findings Overview

### Vanilla WordPress Scan Results

WPScan identified the following issues on the un-hardened WordPress 6.4.3 instance:

#### WordPress Core Vulnerabilities (6 found)

| # | Vulnerability | Severity | CVE | Fixed In |
|---|--------------|----------|-----|----------|
| 1 | Unauthenticated Stored XSS | **High** | — | 6.4.4 |
| 2 | Contributor+ Stored XSS in HTML API | Medium | — | 6.4.5 |
| 3 | Contributor+ Stored XSS in Template-Part Block | Medium | — | 6.4.5 |
| 4 | Contributor+ Path Traversal in Template-Part Block | Medium | — | 6.4.5 |
| 5 | Author+ DOM Stored XSS | Medium | CVE-2025-58674 | 6.4.7 |
| 6 | Contributor+ Sensitive Data Disclosure | Medium | CVE-2025-58246 | 6.4.7 |

#### Plugin Vulnerabilities (1 found)

| Plugin | Vulnerability | CVE | Fixed In |
|--------|--------------|-----|----------|
| Akismet | Unauthenticated Stored XSS | CVE-2015-9357 | 3.1.5 |

#### Server / Configuration Issues

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

The most critical finding is the **Unauthenticated Stored XSS** vulnerability (fixed in WP 6.4.4). This allows an unauthenticated attacker to inject malicious JavaScript that executes when any user (including administrators) views the affected content. Combined with the exposed `admin` username and lack of XML-RPC rate limiting, an attacker could:

1. **Exploit XSS** to steal admin session cookies
2. **Use XML-RPC** for credential brute-forcing against the known `admin` user
3. **Leverage admin access** to install a web shell via the theme/plugin editor (which was not disabled)
4. **Achieve full server compromise** through remote code execution

### How Attackers Could Exploit Them

- **Unauthenticated Stored XSS → Account Takeover:** Inject a payload that steals the admin's cookie. Once authenticated, the attacker uses the built-in theme editor to inject PHP backdoor code.
- **XML-RPC Brute Force:** The `system.multicall` method allows hundreds of password guesses in a single HTTP request, bypassing traditional rate limits.
- **Information Disclosure Chain:** Knowing the exact Apache, PHP, and WordPress versions lets attackers search for specific CVEs and craft targeted exploits.
- **Path Traversal:** The Template-Part Block path traversal (Contributor+) could allow reading sensitive server files.

---

## 3. Remediation Steps

### 3.1 Patching and Updating

Applied in `docker/Dockerfile.hardened`:

- **OS-level patches:** `apt-get update && apt-get upgrade -y` — applies all available Debian security patches to the base image
- **Removed unnecessary packages:** `imagemagick` removed (large attack surface with known CVEs, not needed for basic WordPress operation)
- **WP-CLI installed:** Enables automated WordPress core, plugin, and theme updates at build time

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
- `TraceEnable Off` — disables HTTP TRACE method (prevents XST attacks)
- `X-Frame-Options: SAMEORIGIN` — prevents clickjacking
- `X-XSS-Protection: 1; mode=block` — enables browser XSS filter
- `X-Content-Type-Options: nosniff` — prevents MIME-type sniffing
- `Content-Security-Policy` — restricts resource loading origins
- `Referrer-Policy: strict-origin-when-cross-origin` — controls referrer information
- `Options -Indexes` — disables directory listing
- `xmlrpc.php` blocked via `Require all denied`
- `readme.html`, `license.txt`, `.htaccess` blocked

#### WordPress Hardening (`hardening/wp-config-extra.php`)
- `DISALLOW_FILE_EDIT = true` — disables the theme/plugin code editor in WP admin
- `DISALLOW_FILE_MODS = true` — blocks plugin/theme installation from admin panel
- `WP_DEBUG = false`, `WP_DEBUG_DISPLAY = false` — prevents debug information leakage
- `AUTH_COOKIE_EXPIRATION = 28800` — limits session lifetime to 8 hours

#### Container Hardening (`Dockerfile.hardened`)
- Stripped `setuid`/`setgid` bits from all binaries — reduces privilege escalation vectors
- File permissions locked: `644` for files, `755` for directories
- Ownership set to `www-data:www-data`

### 3.3 Before/After Scan Evidence

| Finding | Vanilla Scan | Hardened Scan |
|---------|-------------|---------------|
| Server header | `Apache/2.4.57 (Debian)` | `Apache` (version hidden) |
| PHP version header | `PHP/8.2.17` exposed | **Removed** |
| XML-RPC | Enabled and accessible | **Blocked** (not detected) |
| `readme.html` | Accessible | **Blocked** (not detected) |
| Security headers | None present | CSP, Referrer-Policy, X-Frame-Options, etc. **added** |
| WP core vulns (6.4.3) | 6 vulnerabilities | 6 vulnerabilities (same base image*) |
| Akismet XSS | Detected | Detected (same bundled plugin*) |

*\*Note: The WordPress core and plugin vulnerabilities persist because both images use the `wordpress:6.4` base. Full remediation would require upgrading to `wordpress:6.8.3+` or using WP-CLI to run `wp core update` and `wp plugin update --all` at build time. The hardening measures applied mitigate the exploitability of these vulnerabilities by:*
- *Blocking the theme/plugin editor (prevents post-exploitation code injection)*
- *Disabling dangerous PHP functions (prevents RCE even if admin access is gained)*
- *Blocking XML-RPC (prevents brute-force amplification)*
- *Adding security headers (mitigates XSS impact)*

---

## 4. Fixed Image Build

### GitHub Repository

**URL:** https://github.com/stefearares/devsecops

Key files:
- `docker/Dockerfile.hardened` — hardened image definition
- `docker/hardening/` — PHP, Apache, and WordPress security configurations
- `.github/workflows/scan.yml` — automated scan + build + rescan pipeline
- `scans/wpscan-vanilla.txt` — pre-remediation scan results
- `scans/wpscan-hardened.txt` — post-remediation scan results

### Docker Hub Image

**URL:** https://hub.docker.com/r/stefearares/wordpress-hardened

Pull the hardened image:
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

---

## 6. DevSecOps Strategy

### How This Workflow Demonstrates Shift-Left Security

Traditional security testing happens late in the development lifecycle — often after deployment. This pipeline **shifts security left** by integrating vulnerability scanning directly into the CI/CD process:

```
Code Push → Scan Vanilla Image → Build Hardened Image → Re-scan Hardened Image
   ↑                                                           |
   └────────── Fix vulnerabilities and push again ─────────────┘
```

#### Key Shift-Left Principles Applied

1. **Automated scanning on every push** — Security checks run automatically when code is pushed to `main`, not as a separate manual process. Developers get immediate feedback on vulnerabilities.

2. **Security as Code** — All hardening configurations (PHP settings, Apache headers, WordPress constants) are version-controlled alongside application code. Security policies are reviewable, auditable, and reproducible.

3. **Immutable infrastructure** — Instead of patching running servers, we rebuild the entire container image with fixes applied. This eliminates configuration drift and ensures every deployment is a known-good state.

4. **Evidence-based remediation** — The pipeline produces before/after scan artifacts, creating an audit trail that proves vulnerabilities were identified and addressed.

5. **Semi-automated feedback loop** — The workflow supports `workflow_dispatch` for manual re-scanning, enabling a remediation loop:
   - Identify vulnerabilities (automated scan)
   - Apply fixes (developer action)
   - Verify fixes (automated re-scan)

6. **Defense in depth** — Multiple layers of hardening are applied:
   - OS-level (package updates, unnecessary software removed)
   - Web server level (Apache security headers, module configuration)
   - Application level (PHP function restrictions, WordPress security constants)
   - Container level (file permissions, setuid bit removal)

### Continuous Improvement

In a production environment, this pipeline would be extended with:
- **Scheduled scans** (cron-triggered workflows) to catch newly disclosed CVEs
- **Slack/email notifications** when new vulnerabilities are found
- **Automated base image updates** using Dependabot or Renovate
- **DAST (Dynamic Application Security Testing)** with tools like OWASP ZAP
- **Image signing** with Cosign/Notary for supply chain security
- **SBOM generation** (Software Bill of Materials) for dependency tracking

---

## Appendix A: Full WPScan Output (Vanilla)

See `scans/wpscan-vanilla.txt` for the complete scan output.

**Summary:** 6 WordPress core vulnerabilities, 1 plugin vulnerability (Akismet), XML-RPC enabled, server version disclosed, no security headers, admin user enumerable.

## Appendix B: Full WPScan Output (Hardened)

See `scans/wpscan-hardened.txt` for the complete scan output.

**Summary:** 6 WordPress core vulnerabilities (same base image), 1 plugin vulnerability (Akismet). XML-RPC blocked, server version hidden, PHP version hidden, security headers added (CSP, Referrer-Policy).
