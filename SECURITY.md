# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| Latest GitHub Release (`v1.0.0` and newer tags on this repository) | Yes |
| Older preview / historical builds | No |

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities, credential leaks, or exploit details.

1. Prefer **GitHub Security Advisories** on this repository:  
   [Report a vulnerability](https://github.com/sunzhengnj/LaunchIcon-OSS/security/advisories/new)
2. Include: affected version / commit, macOS version, reproduction steps, impact, and any suggested fix.
3. Allow reasonable time for triage before public disclosure.

## Scope notes

- LaunchIcon uses Apple Public APIs only and does not read the system Launchpad database.
- Signing certificates, notarization credentials, and API tokens must never be committed.
- If you accidentally commit a secret in a fork or PR, rotate the credential immediately and tell maintainers privately.
