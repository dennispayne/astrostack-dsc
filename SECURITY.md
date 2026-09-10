# Security policy

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose credentials, execute untrusted installers, bypass checksum/domain validation, or operate astronomy hardware unexpectedly.

Use GitHub's **Security** tab and select **Report a vulnerability**. Include the affected resource or script, impact, reproduction steps, and a minimal sanitized example.

## Supported version

This project currently supports the latest commit on the default branch. It does not maintain security support branches or published releases yet.

## Security boundaries

- Installer artifacts must come from the explicit wgfetch path map and match a pinned SHA-256.
- Download-domain allowlists and authentication requirements are human-owned policy.
- Secrets and location data do not belong in manifests, fixtures, logs, issues, or pull requests.
- Hardware-sensitive changes remain audit-only until their safe write behavior is demonstrated.
