# Security scan report

Static security scans of this blueprint before publishing. Live-instance scans (Amazon Inspector, CIS Ubuntu
benchmark) are planned for the release test and are not covered here. Requirement 16 in
`.kiro/specs/sui-rpc-node-blueprint/requirements.md`; per-requirement status in `traceability.md`.

## Summary

| Date | Scope | Result |
|---|---|---|
| 2026-11-02 | Working copy, before the first live test | 6 findings, all fixed; rerun clean |
| 2026-11-05 | Commit `989cac1` (clean clone of exactly the committed files) and the git history | **No findings**; planted control findings were caught |

## 2026-11-05: first commit

Scanned a clean clone of commit `989cac1` (54 files), so untracked local files were not part of the scan.

| Tool | Version | What it checks | Result |
|---|---|---|---|
| [gitleaks](https://github.com/gitleaks/gitleaks) | 8.30.1 | Secrets in every commit of the history, and in the committed files | **0 leaks** (history: 1 commit; rescanned after the second commit, 2 commits, 0 leaks) |
| [ASH](https://github.com/awslabs/automated-security-helper) (Automated Security Helper) | 3.7.1 (tag `v3`, commit `af1206a`), container mode | 10 scanners: bandit, cdk-nag, cfn-nag, checkov, detect-secrets, grype, npm-audit, opengrep, semgrep, syft | **All 10 passed, 0 findings at every severity** (including Low and Info); semgrep and opengrep each ran 161 rules over all 54 files |
| [ShellCheck](https://www.shellcheck.net/) | 0.11.0 | Shell scripts, at the CI severity (`-S warning`) and at `-x -S style` | Clean |
| `scripts/validate.sh` | - | Installs the blueprint into a fresh Node Runners checkout, runs the integration tests, synthesizes every sample (cdk-nag runs inside synth) | 41/41 tests, 5/5 samples synthesize |

**Control checks (to show a clean result is real):**
- gitleaks: a file with a planted, fake AWS access key was reported as a leak.
- ASH: a copy of the commit with `actions/checkout@v4` (a mutable tag, the issue fixed on 2026-11-02) was flagged by
  semgrep and opengrep.

## 2026-11-02: before the first live test

ASH 3.7.1 (same 10 scanners) on the working copy found **6 findings**, all fixed:

| Finding | Scanner | Where | Fix |
|---|---|---|---|
| High-entropy strings (2) | detect-secrets | `user-data/common/install-sui-binaries.sh`, the pinned genesis SHA-256 digests | False positive: public digests of public files. Allowlisted inline with `# pragma: allowlist secret` and a comment explaining why |
| Mutable GitHub Action tags (4, the same 2 lines reported by two scanners) | semgrep, opengrep | `.github/workflows/ci.yml`, `actions/checkout@v4` and `actions/setup-node@v4` | Valid supply-chain point: pinned to commit SHAs (both v4.4.0), ADR-0017 |

The rerun after the fixes reported 0 findings across all 10 scanners.

A second secrets, CVE and licence-header scanner was also run that day: no secrets, no CVEs (the package has no
runtime dependencies). It flagged the 9 source files for not carrying the full Apache 2.0 header text; the
community blueprints use SPDX identifiers instead, which ADR-0018 adopts.

## Design checks (manual)

Against the framework's blueprint security checklist (`docs/ageai-blueprint-security-review.md` in Node Runners):
outbound URLs limited to MystenLabs GitHub releases and genesis, Sui's snapshot and checkpoint endpoints and EC2
instance metadata; no `eval`, no download-and-run, no credentials in configuration; `rm -rf` only on the temporary
download directory; RPC bound to the internal IP and allowed only from the VPC; metrics and admin interfaces on
loopback; the node runs as an unprivileged user. See the README's Security Considerations.

## Not yet done

- Amazon Inspector and the CIS Ubuntu benchmark on a live instance (release test).
- A threat model.
