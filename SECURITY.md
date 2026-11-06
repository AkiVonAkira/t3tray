# Security

Report a vulnerability through this repository's GitHub **Security** tab using **Report a vulnerability**. Do not put credentials, session data, or an exploit against a live machine in a public issue. If private reporting is unavailable, open an issue asking for a private contact without disclosing the vulnerability.

Only the latest t3tray release receives security fixes. T3 Code server vulnerabilities belong to upstream [pingdotgg/t3code](https://github.com/pingdotgg/t3code/security).

t3tray runs upstream executables as your Windows user. Those processes can access your files and credentials. Initial server downloads use upstream SHA256SUMS. The installer checks its executable against this project's release SHA256SUMS. Checksums share the release account's trust boundary and are not signatures. Public releases include GitHub build provenance, which you can verify with `gh attestation verify t3tray.exe --repo AkiVonAkira/t3tray`. Private releases do not include attestations unless the hosting plan supports them.

The default listen address is localhost. Binding to `0.0.0.0` exposes the server to other machines. Set a firewall rule that allows only trusted networks, and use T3 authentication. Do not expose an unauthenticated server to the internet.

Logs and `.t3` may contain private paths and session data. Review and redact them before sharing. Uninstall keeps `.t3` even with `-Purge`.
