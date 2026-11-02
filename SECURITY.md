# Security policy

DebloatHub runs with administrator rights and changes system settings, so security problems matter. Thank you for reporting them responsibly.

## Supported versions

Only the [latest release](https://github.com/GrappurA/DebloatHub/releases/latest) gets fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting instead:
[Security › Report a vulnerability](https://github.com/GrappurA/DebloatHub/security/advisories/new).

Include what you found, how to reproduce it and the DebloatHub version (shown in the window title). You should get an answer within a week.

Examples of what counts:
- a way to make DebloatHub (elevated) write or delete files or registry keys outside what a tweak describes;
- a tweak that silently weakens security in a way its description and cons do not mention;
- a release file that does not match the source in this repository or its `SHA256SUMS.txt`.

## Verifying a download

Each release lists the SHA-256 of its files in `SHA256SUMS.txt`. In PowerShell: `Get-FileHash DebloatHub.zip`, then compare.
