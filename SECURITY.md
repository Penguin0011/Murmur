# Security

Murmur is pre-release software with access to microphone audio, meeting audio, focused fields, and local transcript history. Review the requested macOS permissions before enabling capture or correction learning. [Certain]

Please report suspected vulnerabilities privately through GitHub's **Report a vulnerability** control when available. If it is unavailable, contact the repository owner through an existing private channel to arrange disclosure. Do not put credentials, recordings, transcripts, or reproduction data from real users into public issues. No private reporting channel is guaranteed to be configured yet. [Certain]

## Local checks

Install [Gitleaks](https://github.com/gitleaks/gitleaks) (the CI version is 8.30.1), then run from the repository root: [Certain]

```sh
gitleaks git . --log-opts='--all --full-history' --redact=100 --ignore-gitleaks-allow
gitleaks dir . --redact=100 --ignore-gitleaks-allow
git log --all --format=fuller | gitleaks stdin --redact=100 --ignore-gitleaks-allow
```

The history scan covers fetched refs only; a clean result does not cover unfetched branches, hosted comments, attachments, logs, releases, or private data formats the scanner does not recognize. CI uses a read-only token, does not persist checkout credentials, and uploads no scan report. [Certain]

Before changing repository visibility, inventory remote branches, tags and pull-request refs, scan their full history, and review hosted content separately. Keep audit reports containing personal information or incident details outside the repository. A removed credential must be revoked or rotated; deleting its current file or rewriting history alone does not invalidate it. [Certain]

## Data and development tools

Use synthetic data for fixtures and examples. Store provider keys through Settings in the macOS Keychain. Ignore rules are a safeguard against accidental staging, and do not remove data already committed. [Certain]

The optional scripts under `app/tools/` include live provider benchmarks that can read configured Keychain credentials and send supplied text or audio to the selected provider. Read the script and its arguments before running it; the offline checks in CONTRIBUTING.md do not require provider keys. [Certain]

The app is a desktop client, with no repository-hosted backend or account service. Custom servers are user-selected trust boundaries; plain HTTP outside loopback exposes audio or transcript content to the network path and is disclosed in Settings. Local history is protected with filesystem permissions, rather than application-level encryption. [Certain]
