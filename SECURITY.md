# Security Policy

## Supported versions

Security fixes are applied to the latest prerelease on `main`.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this
repository. Do not open a public issue for a suspected vulnerability or include
credentials, private endpoints, or sensitive user data in a report.

Include the affected version, impact, reproduction steps, and any proposed
mitigation. You can expect an acknowledgement within seven days. Disclosure
timing will be coordinated after the issue is understood and a fix is ready.

## Credential handling

The signed Chess Coach app installed in Applications stores inference keys in
macOS Keychain and sends them only to the endpoint selected by the user.
Development and relocated builds keep inference keys in memory for the current
session only. Reports involving leaked or exposed credentials should revoke
those credentials immediately before submitting the report.
