---
name: dotnet-devcert-trust
description: Diagnose and fix .NET HTTPS dev certificate trust issues on Linux. Covers the full certificate lifecycle from generation to system CA bundle inclusion, with distro-specific guidance for Ubuntu, Fedora, Arch, and WSL2.
invocable: false
---

# .NET Dev Certificate Trust on Linux

## When to Use This Skill

Use this skill when:
- Redis TLS connections fail with `UntrustedRoot` or `RemoteCertificateNameMismatch` in Aspire
- `dotnet dev-certs https --check --trust` returns exit code 7
- HTTPS localhost connections fail with certificate validation errors
- After running `dotnet dev-certs https --clean` and needing to restore trust
- Setting up a new Linux dev machine for .NET HTTPS development
- Aspire dashboard or inter-service gRPC calls fail with TLS errors
- Upgrading from Aspire < 13.1.0 (which didn't use TLS on Redis by default)

## The Problem

On Windows and macOS, `dotnet dev-certs https --trust` handles everything automatically — it generates the certificate, installs it in the user store, and adds it to the system trust store. On Linux, **it does almost nothing useful**. The command generates the cert and places it in the user store, but:

1. It does **not** export the certificate to the system CA directory
2. It does **not** run `update-ca-certificates` to rebuild the CA bundle
3. It does **not** add the cert to browser trust stores (NSS/NSSDB)
4. The `--trust` flag silently succeeds but the cert remains untrusted

This means .NET applications, OpenSSL, curl, and browsers all reject the dev certificate — even though `dotnet dev-certs https --check` reports it exists.

### Why This Surfaces with Aspire 13.1.0+

Prior to Aspire 13.1.0, Redis connections used plaintext. Starting with 13.1.0, Aspire enables TLS on Redis by default. If your dev cert isn't trusted at the system level, Redis connections fail immediately with:

```
System.Security.Authentication.AuthenticationException:
  The remote certificate is invalid because of errors in the certificate chain: UntrustedRoot
```

## How Linux Certificate Trust Works

Understanding the architecture prevents cargo-cult debugging:

```
┌─────────────────────────────────────────────────────┐
│ Application (.NET, curl, OpenSSL)                   │
│   reads: /etc/ssl/certs/ca-certificates.crt         │
│          (consolidated CA bundle)                    │
└──────────────────────┬──────────────────────────────┘
                       │ built by
┌──────────────────────▼──────────────────────────────┐
│ update-ca-certificates                              │
│   reads from:                                        │
│     /usr/share/ca-certificates/      (distro CAs)   │
│     /usr/local/share/ca-certificates/ (local CAs)   │
│   writes to:                                         │
│     /etc/ssl/certs/ca-certificates.crt (bundle)     │
│     /etc/ssl/certs/*.pem (individual symlinks)      │
└─────────────────────────────────────────────────────┘
```

**Key insight:** Placing a `.crt` file in `/usr/local/share/ca-certificates/` is necessary but **not sufficient**. The consolidated bundle at `/etc/ssl/certs/ca-certificates.crt` must be rebuilt by running `update-ca-certificates`. Applications read the bundle, not the individual files.

## 5-Point Diagnostic Procedure

Run these checks in order. Stop at the first FAIL and apply its fix before continuing.

### Check 1: Dev Cert Existence

```bash
dotnet dev-certs https --check
echo "Exit code: $?"
```

| Exit Code | Meaning | Action |
|-----------|---------|--------|
| 0 | Cert exists in user store | PASS — continue |
| Non-zero | No valid dev cert | Run `dotnet dev-certs https` |

### Check 2: System Trust Store — Single Cert, Correct Permissions

```bash
ls -la /usr/local/share/ca-certificates/ | grep -iE 'dotnet|aspnet'
```

| Result | Meaning |
|--------|---------|
| Only `dotnet-dev-cert.crt` with `-rw-r--r--` (644) | PASS |
| Multiple cert files, wrong permissions, or stale `aspnet*` files | FAIL |

**Common stale files from previous sessions:**

| File | Problem |
|------|---------|
| `aspnetcore-dev.crt` | Often created with `0600` permissions (unreadable by `update-ca-certificates`) |
| `aspnet/https.crt` | Old convention, may have a different fingerprint than current dev cert |
| `dotnet-dev-cert.crt` with `0600` | Correct name but wrong permissions |

**Fix:**
```bash
# Remove ALL stale cert files
sudo rm -f /usr/local/share/ca-certificates/aspnetcore-dev.crt
sudo rm -rf /usr/local/share/ca-certificates/aspnet/

# Ensure correct permissions on the dev cert (if it exists)
sudo chmod 644 /usr/local/share/ca-certificates/dotnet-dev-cert.crt
```

### Check 3: CA Bundle Inclusion

This is the most commonly failed check. The cert file exists but was never added to the bundle.

```bash
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
  /usr/local/share/ca-certificates/dotnet-dev-cert.crt
```

| Result | Meaning |
|--------|---------|
| `dotnet-dev-cert.crt: OK` | PASS — cert is in the consolidated bundle |
| `error 20 at 0 depth lookup: unable to get local issuer certificate` | FAIL — bundle was never rebuilt |
| `error 2 at 0 depth lookup: unable to get issuer certificate` | FAIL — same issue, different OpenSSL version |

**Fix:**
```bash
sudo update-ca-certificates
# Expected output includes "1 added" or similar

# Re-verify
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
  /usr/local/share/ca-certificates/dotnet-dev-cert.crt
```

### Check 4: Environment Variable Overrides

SSL environment variables can redirect certificate lookups away from the system bundle:

```bash
echo "SSL_CERT_DIR=${SSL_CERT_DIR:-<unset>}"
echo "SSL_CERT_FILE=${SSL_CERT_FILE:-<unset>}"
echo "DOTNET_SSL_CERT_DIR=${DOTNET_SSL_CERT_DIR:-<unset>}"
echo "DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER=${DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER:-<unset>}"
```

| Result | Meaning |
|--------|---------|
| All `<unset>` | PASS |
| Any variable set | FAIL — may redirect cert lookups |

**Fix:** Remove the offending variables from your shell profile (`~/.bashrc`, `~/.zshrc`, `~/.profile`) and start a new shell.

### Check 5: Symlink Integrity

Stale symlinks from previously removed certificates can confuse OpenSSL:

```bash
find /etc/ssl/certs/ -xtype l 2>/dev/null | head -5
```

| Result | Meaning |
|--------|---------|
| No output | PASS |
| Broken symlinks listed | FAIL |

**Fix:**
```bash
sudo update-ca-certificates --fresh
# Rebuilds ALL symlinks from scratch
```

## Full Recovery Procedure

When multiple checks fail or you want a clean slate, run this complete sequence:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== .NET Dev Certificate Trust Recovery ==="

# Step 1: Remove ALL stale certificate files
echo "--- Removing stale certificate files ---"
sudo rm -f /usr/local/share/ca-certificates/aspnetcore-dev.crt
sudo rm -rf /usr/local/share/ca-certificates/aspnet/
sudo rm -f /usr/local/share/ca-certificates/dotnet-dev-cert.crt

# Step 2: Clean and regenerate dev cert
echo "--- Regenerating dev certificate ---"
dotnet dev-certs https --clean
dotnet dev-certs https

# Step 3: Export as PEM and install to system trust store
echo "--- Installing to system trust store ---"
dotnet dev-certs https --export-path /tmp/dotnet-dev-cert.crt --format PEM --no-password
sudo cp /tmp/dotnet-dev-cert.crt /usr/local/share/ca-certificates/dotnet-dev-cert.crt
sudo chmod 644 /usr/local/share/ca-certificates/dotnet-dev-cert.crt
rm /tmp/dotnet-dev-cert.crt

# Step 4: Rebuild CA bundle (CRITICAL — most commonly missed step)
echo "--- Rebuilding CA bundle ---"
sudo update-ca-certificates

# Step 5: Verify
echo "--- Verifying ---"
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
  /usr/local/share/ca-certificates/dotnet-dev-cert.crt

echo "=== Done! Restart your .NET application. ==="
```

Save this as `~/fix-devcert.sh` and run with `bash ~/fix-devcert.sh` when needed.

## Distro-Specific Notes

### Ubuntu / Debian

The procedure above is written for Ubuntu/Debian and works as-is.

- **CA directory:** `/usr/local/share/ca-certificates/`
- **Bundle command:** `sudo update-ca-certificates`
- **Bundle output:** `/etc/ssl/certs/ca-certificates.crt`
- **Cert format:** PEM with `.crt` extension required

### Fedora / RHEL / CentOS

Fedora uses `update-ca-trust` instead of `update-ca-certificates`:

```bash
# Export cert
dotnet dev-certs https --export-path /tmp/dotnet-dev-cert.pem --format PEM --no-password

# Install to Fedora trust store (different directory!)
sudo cp /tmp/dotnet-dev-cert.pem /etc/pki/ca-trust/source/anchors/dotnet-dev-cert.pem
sudo chmod 644 /etc/pki/ca-trust/source/anchors/dotnet-dev-cert.pem
rm /tmp/dotnet-dev-cert.pem

# Rebuild trust bundle
sudo update-ca-trust

# Verify
openssl verify /etc/pki/ca-trust/source/anchors/dotnet-dev-cert.pem
```

**Key differences:**
| | Ubuntu/Debian | Fedora/RHEL |
|--|---------------|-------------|
| CA directory | `/usr/local/share/ca-certificates/` | `/etc/pki/ca-trust/source/anchors/` |
| Rebuild command | `update-ca-certificates` | `update-ca-trust` |
| Bundle path | `/etc/ssl/certs/ca-certificates.crt` | `/etc/pki/tls/certs/ca-bundle.crt` |
| Extension | `.crt` | `.pem` (any extension works) |

### Arch Linux

Arch uses the same `update-ca-trust` approach as Fedora:

```bash
sudo cp /tmp/dotnet-dev-cert.pem /etc/ca-certificates/trust-source/anchors/dotnet-dev-cert.pem
sudo chmod 644 /etc/ca-certificates/trust-source/anchors/dotnet-dev-cert.pem
sudo update-ca-trust
```

### WSL2

WSL2 runs a real Linux kernel with its own certificate store — separate from the Windows host. The standard Ubuntu/Debian procedure works, but watch for:

1. **Shared filesystem (`/mnt/c/`)** — cert files on the Windows filesystem have Windows permissions that may not be 644. Always copy to a native Linux path first.
2. **systemd not running** — some older WSL2 setups don't have systemd, which `update-ca-certificates` hooks may depend on. If the command hangs, try `sudo dpkg-reconfigure ca-certificates` instead.
3. **Docker Desktop integration** — If using Docker Desktop's WSL2 backend, containers inherit the WSL2 distro's CA bundle. Fixing trust in WSL2 fixes it for containers too.

## Aspire-Specific Considerations

### Redis TLS (Aspire 13.1.0+)

Aspire 13.1.0 enables TLS on Redis by default. If you see:

```
UntrustedRoot
```

in Redis connection errors, the dev cert isn't trusted at the system level. Run the full recovery procedure above.

### Aspire Dashboard HTTPS

The Aspire dashboard uses the dev cert for HTTPS. If the dashboard shows certificate warnings in the browser, the cert isn't in the browser's trust store. For development, clicking through the warning is acceptable — the system-level trust (needed for Redis, gRPC, etc.) is the priority.

### ASPIRE_ALLOW_UNSECURED_TRANSPORT

Setting `ASPIRE_ALLOW_UNSECURED_TRANSPORT=true` is a **workaround**, not a fix. It disables TLS for inter-service communication, which:

- Masks the underlying trust issue
- Doesn't match production behavior
- May cause different bugs than what you'd see in production

Fix the cert trust instead.

## Certificate Lifecycle

The dev cert is valid for 1 year from creation. When it expires:

1. `dotnet dev-certs https --check` will report no valid cert
2. Run the full recovery procedure to generate a new cert
3. The old cert file in `/usr/local/share/ca-certificates/` will be replaced
4. `update-ca-certificates` will swap the old cert for the new one in the bundle

**No system reboot is required.** Applications pick up the new bundle on next TLS handshake (restart your app).

## Automation: CI/CD Pipelines

In CI/CD on Linux runners, dev certs are rarely needed (you typically test against real certificates or disable TLS validation in test harnesses). However, if your integration tests require trusted dev certs:

### GitHub Actions

```yaml
- name: Trust .NET Dev Certificate
  run: |
    dotnet dev-certs https
    dotnet dev-certs https --export-path /tmp/dotnet-dev-cert.crt --format PEM --no-password
    sudo cp /tmp/dotnet-dev-cert.crt /usr/local/share/ca-certificates/dotnet-dev-cert.crt
    sudo chmod 644 /usr/local/share/ca-certificates/dotnet-dev-cert.crt
    rm /tmp/dotnet-dev-cert.crt
    sudo update-ca-certificates
```

### Azure DevOps

```yaml
- script: |
    dotnet dev-certs https
    dotnet dev-certs https --export-path /tmp/dotnet-dev-cert.crt --format PEM --no-password
    sudo cp /tmp/dotnet-dev-cert.crt /usr/local/share/ca-certificates/dotnet-dev-cert.crt
    sudo chmod 644 /usr/local/share/ca-certificates/dotnet-dev-cert.crt
    rm /tmp/dotnet-dev-cert.crt
    sudo update-ca-certificates
  displayName: 'Trust .NET Dev Certificate'
```

## Common Pitfalls

### 1. Cert placed but bundle never rebuilt

**Symptom:** Cert file exists in `/usr/local/share/ca-certificates/` but `openssl verify` fails.

**Cause:** `update-ca-certificates` was never run after placing the file.

**Fix:** `sudo update-ca-certificates`

This is the single most common mistake. The CA directory is an **input** to the bundle generation process, not the bundle itself.

### 2. Stale cert files with wrong permissions

**Symptom:** `update-ca-certificates` runs but reports `0 added`.

**Cause:** Cert files with `0600` permissions are unreadable by `update-ca-certificates` (which runs as root but reads files through a process that may check world-readability). Files must be `644`.

**Fix:** `sudo chmod 644 /usr/local/share/ca-certificates/*.crt`

### 3. Multiple cert files from different sessions

**Symptom:** `update-ca-certificates` adds multiple certs, but applications still fail.

**Cause:** Old cert files from previous `dotnet dev-certs https --clean` / regenerate cycles remain in the CA directory. The old cert's fingerprint doesn't match the current dev cert.

**Fix:** Remove all `dotnet*` and `aspnet*` files, then re-export the current cert.

### 4. Fingerprint mismatch after clean/regenerate

**Symptom:** `openssl verify` passes but .NET still reports `UntrustedRoot`.

**Cause:** The cert in `/usr/local/share/ca-certificates/` was exported from a **previous** dev cert. After `dotnet dev-certs https --clean && dotnet dev-certs https`, a **new** cert with a different fingerprint was generated. The system trusts the old cert, not the new one.

**Fix:** Re-export and reinstall:
```bash
dotnet dev-certs https --export-path /tmp/dotnet-dev-cert.crt --format PEM --no-password
sudo cp /tmp/dotnet-dev-cert.crt /usr/local/share/ca-certificates/dotnet-dev-cert.crt
sudo update-ca-certificates
```

### 5. Using --trust and assuming it worked

**Symptom:** `dotnet dev-certs https --trust` returns exit code 0 but nothing is actually trusted.

**Cause:** On Linux, `--trust` attempts to add the cert to the OpenSSL trust store but **does not call `update-ca-certificates`**. The operation "succeeds" from dotnet's perspective but the bundle remains unchanged.

**Fix:** Don't rely on `--trust` on Linux. Follow the manual procedure in this skill.

## Quick Reference

```bash
# Generate dev cert (if missing)
dotnet dev-certs https

# Export as PEM
dotnet dev-certs https --export-path /tmp/dotnet-dev-cert.crt --format PEM --no-password

# Install to system trust (Ubuntu/Debian)
sudo cp /tmp/dotnet-dev-cert.crt /usr/local/share/ca-certificates/dotnet-dev-cert.crt
sudo chmod 644 /usr/local/share/ca-certificates/dotnet-dev-cert.crt
sudo update-ca-certificates

# Verify trust
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
  /usr/local/share/ca-certificates/dotnet-dev-cert.crt

# Check cert details
openssl x509 -in /usr/local/share/ca-certificates/dotnet-dev-cert.crt -noout -subject -dates -fingerprint

# Nuclear option: full clean + rebuild
dotnet dev-certs https --clean && dotnet dev-certs https
```

## Related Skills

- `dotnet-skills:aspire-configuration` — Aspire AppHost configuration including TLS settings
- `dotnet-skills:aspire-service-defaults` — Service defaults including HTTPS configuration
