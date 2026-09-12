# Security policy

## Supported versions

The current `main` branch is supported.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose prompts, local files, downloaded weights, or a network service. Contact the repository maintainer privately through the security contact configured on GitHub, with a description, impact, and reproduction steps.

This server intentionally binds to `127.0.0.1` by default and does not provide authentication. Treat any deployment on a non-loopback interface as a separate security boundary requiring a reverse proxy, authentication, and firewall rules.
