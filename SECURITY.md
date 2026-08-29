# Security Policy

CADQuickLook is a code-signed, notarized macOS app that ships with a Sparkle
update feed. Vulnerabilities in the file parsers (STEP, IGES, BREP, STL, DXF
are all parsed from untrusted files, including by Finder's Quick Look
extensions) or in the update mechanism are in scope.

## Reporting

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/lflanagan/CADQuickLook/security/advisories/new)
rather than in a public issue. Include the macOS and app versions and, where
possible, a file that reproduces the problem.

You should get an acknowledgement within a week. Fixes ship as a new release
through the app's update feed.

## Supported versions

Only the latest release is supported.
