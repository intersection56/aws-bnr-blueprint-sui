# Implementation Plan

**Provenance:** Phases 1-6 were done on 2026-11-02 before this spec existed and are recorded here retroactively.
Phases 7-9 are the remaining work. Checkboxes: `[x]` done, `[ ]` open, `[~]` partly done.

## Phase 1: Package and protocol declaration

- [x] 1. Create the npm package and `"aws-blockchain-node-runner"` field
  - `package.json`: name, peer dependency, `files`, networks, modes, configurations, instance types, ports, monitoring, storage, `SUI_*` defaults
  - _Requirements: 1.1, 1.2, 1.5, 2.1, 3.1-3.3, 7.2-7.4_
- [x] 2. Create the four samples (mainnet x86, mainnet ARM, mainnet HA, testnet)
  - _Requirements: 1.4, 3.5, 12.1, 12.2_

## Phase 2: Install and configure

- [x] 3. Versioned configuration scripts with install/run dispatch (`sui-node-v1.82.3-full.sh`, `sui-node-v1.83.0-full.sh`)
  - _Requirements: 2.3-2.5, 8.3_
- [x] 4. `install-sui-binaries.sh`: release lookup, digest verification, extraction, genesis pinning
  - _Requirements: 2.2, 2.4, 4.1-4.6_
- [x] 5. `write-fullnode-config.sh`: IMDSv2, input validation, seed peers, pruning, indexing, archive fallback, atomic write
  - _Requirements: 6.1-6.7, 7.1, 7.3-7.5_
- [x] 6. `download-snapshot.sh`: formal snapshot restore as `bcuser`, idempotence guard, retries
  - _Requirements: 5.1-5.5, 9.1_

## Phase 3: Service, re-run safety, monitoring

- [x] 7. `node.sh`: validation, install phase, ownership, `node.service`, sentinel
  - _Requirements: 8.1, 8.2, 9.1-9.4_
- [x] 8. `syncchecker.sh`: `c1_*` metrics, traffic shaping control, robust metric parsing
  - _Requirements: 10.1-10.4, 11.1, 11.2_

## Phase 4: Verification tooling

- [x] 9. Integration tests (25) against the real `ConfigurationLoader`
  - _Requirements: 1.3, 15.1_
- [x] 10. `scripts/validate.sh` (clean Framework checkout, tests, credential-free `cdk synth`) and CI workflow
  - _Requirements: 15.2, 15.3_
- [x] 11. Pin CI actions to commit SHAs (ASH finding)
  - _Requirements: 15.4_

## Phase 5: Documentation

- [x] 12. README following the framework template
  - _Requirements: 14.1-14.3, 12.3_
- [x] 13. Cost documentation: unit prices, measured traffic model, busy-RPC placement scenarios, instance store vs EBS, sources
  - _Requirements: 13.1-13.5, 11.3_
- [x] 14. Test plan and results template (now `docs/testnet-test-report.md`)
  - _Requirements: 18.1_
- [x] 15. Retroactive spec (`requirements.md`, `design.md`, `tasks.md`, `traceability.md`) and ADRs (`docs/adr/`)
  - _Requirements: all (process)_

## Phase 6: Pre-deploy security

- [x] 16. ShellCheck, cdk-nag, framework security checklist
  - _Requirements: 15.3, 16.1_
- [x] 17. ASH (container mode) and a second scanner (secrets, semgrep, CVE, licence headers); fix or allowlist findings; rerun clean
  - _Requirements: 16.1, 16.5_
- [~] 18. No upload without consent
  - One scanner sent files to an AI service in the owner's own AWS account despite its scan-only flag
  - _Requirements: 16.4_

## Phase 7: Live verification (next)

- [x] 19. Owner decisions: AWS test account/profile, region, instance size, who runs the test (2026-11-03)
  - _Requirements: 18.1_
- [x] 20. Pre-flight read-only checks: identity, default VPC, vCPU quota, instance-type availability; budget alert in place (2026-11-03)
  - _Requirements: 18.1_
- [x] 21. One-day testnet deployment; results in `docs/testnet-test-report.md`
  - Day 1 (2026-11-03): deploy, install, verification, restore passed; stopped during index build; issue 1 found
  - _Requirements: 2.4, 4.*, 5.*, 6.*, 7.*, 8.*, 9.4, 10.*, 11.1-11.2, 18.2_
- [x] 21a. Fix issue 1 (shaping during bootstrap; snapshot retry/parallelism settings); tests, ShellCheck, ASH; ADR-0019
  - Done 2026-11-03: `node.sh` stops shaping before install; `syncchecker.sh` keeps it off during bootstrap and when disabled; `SUI_SNAPSHOT_MAX_RETRIES` / `SUI_SNAPSHOT_PARALLEL_DOWNLOADS`; 4 new tests; ADR-0019. Live verification in the redeploy test (task 23)
  - _Requirements: 5.6, 11.1, 11.2, 11.4, 11.5_
- [x] 21b. Fix issue 2 (`RequiresMountsFor=/data` + `ConditionPathIsMountPoint=/data`, ADR-0020; first version flawed and revised) and issue 3 (`systemctl cat` check); tests
  - Plain reboot verified live 2026-11-03; stop/start path in task 25a
  - _Requirements: 8.5, 11.1, 11.2_
- [~] 22. Live-instance scans: Amazon Inspector done 2026-11-06 (package + network reachability); CIS Ubuntu benchmark not completed (Inspector CIS scan failed twice)
  - _Requirements: 16.3_
- [x] 23. Optional: redeploy test (re-run contract)
  - Done 2026-11-03: in-place stop/start, healthy after 3h43m; issue 1 fix verified; issues 2 and 3 found and fixed
  - _Requirements: 9.1-9.3_
- [x] 24. Record measurements (15.5) and update the README cost model, HA grace period and storage projection
  - Done 2026-11-03: measured inputs in the README; HA grace period 1,440 min; HA behaviour still needs an HA deployment
  - _Requirements: 12.2, 13.1, 18.3_
- [~] 25. Teardown and cost check
  - Torn down 2026-11-03 23:35 UTC; Cost Explorer check pending (~24 h)
  - _Requirements: 18.1_

## Phase 8: Before publishing

- [x] 24a. Align with the community blueprints (2026-11-05): absolute doc links, Support section pointing at this repository, Maintenance section; `release-watch` workflow, `check-release.sh`, `bump.sh` (ADR-0021); bump both networks to v1.83.1
  - _Requirements: 2.5, 2.6_
- [x] 24b. Owner decisions 2026-11-05 applied: intended use and 3-node HA (ADR-0024); in-place upgrades with the never-downgrade safeguard (`sui-version.sh`, installer, `scripts/upgrade-in-place.sh`, `SUI_ALLOW_DOWNGRADE`; ADR-0022); plain `/health` plus stack-level lag metric and documented alarm (ADR-0023); shaping kept at 40 Mbit/s (ADR-0013); copyright confirmed (ADR-0018); GitHub `intersection56` in README and `package.json`; testnet HA sample; release watch daily; README regions, HA, upgrades, lag alarm, AWS vs bare metal, 3-node cost column
  - Verified locally: 41 Jest tests, 5/5 samples synth, ShellCheck clean; upgrade script tested against a stubbed AWS CLI
  - _Requirements: 2.3, 2.7, 2.8, 10.5, 12.5, 12.6, 14.4_
- [x] 25a. **Final release test** (done 2026-11-06: pass with issues; issues 4 and 5 fixed; results in `docs/testnet-test-report.md`) of the finished build (v1.83.1, not yet deployed live). Scope decided by the Owner 2026-11-05: **testnet only**, single node and 3-node HA (scenario A); **no mainnet**. Estimated ~11-13 h if both parts run in parallel (~20-23 h one after the other) and ~$65-75 in total (us-east-1 on-demand; prices re-checked 2026-11-05); raise the $50 budget alert first (~$150 is enough).
  - **Part 1, testnet single node (~10 h, ~$17):** fresh `cdk deploy`; Inspector + CIS scans (task 22); plain reboot; **in-place upgrade** to the newest testnet release with `scripts/upgrade-in-place.sh` (or skip if none newer exists), then a live **stop/start** confirming the safeguard keeps the newer release and the issue-2 stop/start path; create the **lag alarm**, stop `node.service` for ~10 minutes and confirm it fires and clears.
  - **Part 2, testnet 3-node HA (`.env-testnet-sui-node-full-ha`, ~$5.16/h; core ~9-11 h, ~$46-57):** deploy; all 3 healthy behind the ALB; gRPC-Web through the ALB; terminate one node and confirm the other 2 keep serving and the replacement becomes healthy; per-AZ placement, including how the group handles us-east-1e (no `i7i.4xlarge` there); stack-level metric covers all nodes. Optional: a rolling upgrade of all 3 nodes (+~12 h, total ~$108-124). HA instances can't be stopped overnight (the group replaces them): run it in one session.
  - ~~Part 3, mainnet single node~~: dropped by the Owner 2026-11-05. Mainnet bootstrap time, disk use against the 3,750 GB disk and egress stay modelled (task 34).
  - _Requirements: 2.7, 2.8, 8.5, 9.1-9.3, 10.5, 12.*, 16.3, 18_
- [x] 26. Decide licence; align `LICENSE`, `package.json`, headers (Apache-2.0, aligned with the community blueprints; ADR-0018). Copyright holder confirmed by the Owner 2026-11-05
  - _Requirements: 17.1, 17.2_
- [x] 27. Answer the open questions in `requirements.md`: all answered (2026-11-05; cost ceiling not applicable and catalog submission confirmed 2026-11-09)
  - _Requirements: open questions_
- [x] 28. `git init`, first commit; rerun ASH and a secrets scan over the history (gitleaks)
  - Done 2026-11-05 on commit `55d2d64` (clean clone): gitleaks 8.30.1 0 leaks (history and files; control finding caught); ASH 3.7.1 (`v3` = `af1206a`, container mode on Finch) 0 findings across 10 scanners at every severity (control finding caught by semgrep and opengrep); `validate.sh` 41/41 tests, 5/5 synth
  - _Requirements: 16.2_
- [ ] 29. Threat model; any scan that uploads files to a remote service only with explicit consent
  - _Requirements: 16.2, 16.4_
- [ ] 30. Consider systemd sandboxing for `node.service` once write paths are confirmed
  - _Requirements: 8.2 (hardening)_
- [~] 31. Replace `<org>` placeholders (done 2026-11-05: `intersection56`; `package.json` `author`/`repository`/`homepage`/`bugs`); publish to GitHub; tag the release (`v2.0.0`, matching `package.json`); submit for the community catalog
  - _Requirements: 1.1_

## Phase 9: Optional

- [ ] 32. CloudWatch dashboard template (framework workflow Step 11)
- [~] 33. Alarms: lag alarm documented with a stack-level metric (2026-11-05, ADR-0023); disk-usage, `NetworkOut` and `UnHealthyHostCount` alarms still open
- [ ] 34. Mainnet trial: not part of the release test (Owner decision 2026-11-05); would measure bootstrap, disk use against 3,750 GB and egress
- [ ] 35. File the upstream framework reports listed in `docs/testnet-test-report.md` ("Findings for the Node Runners framework"), including report 6 (separate ALB routing health from ASG replacement)
