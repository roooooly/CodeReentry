# Security policy

## Reporting a vulnerability

Please do not publish secrets, private paths, session content, or exploit details in a
public issue. Use GitHub's private vulnerability-reporting feature for this repository.

Include the affected version, reproduction conditions, expected impact, and a minimal
sanitized example. Do not include real credentials or user data.

## Scope

Security-sensitive areas include:

- Keychain storage and backup behavior;
- command, launcher, MCP, and script-plugin permission boundaries;
- session parsing and path handling;
- diagnostic-log redaction;
- update signing and distribution.

Local ad-hoc builds are intended for development. Public binaries must be signed with a
Developer ID Application certificate, notarized, and verified independently.
