# ADR-0018: Licence and copyright holder

- **Status:** Accepted by owner (2026-11-05). Publishing precondition met: the Owner confirmed the copyright holder under Amazon's open-source process (2026-11-05)
- **Date raised:** 2026-11-02
- **Requirements:** R17

## Context
The first build was inconsistent:
- `LICENSE` was **MIT No Attribution**, Copyright Amazon.com, Inc. (copied from the framework).
- `package.json` said `"license": "Apache-2.0"`.
- All 9 source files carry `SPDX-License-Identifier: Apache-2.0`; 8 also carry `Copyright Amazon.com, Inc. or its affiliates`.
- A licence-header scanner flagged all 9 files because they lack the full Apache 2.0 header text.

The framework itself is MIT-0. On 2026-11-05 the five published community blueprints were checked
(Avalanche, Arbitrum, Arc, Robinhood: `karimakacem`; TRON: `ytaws`). All five use the same convention:
- `LICENSE`: the unmodified Apache License 2.0 text (Avalanche, Arbitrum, Arc and Robinhood byte-identical; TRON
  differs only in whitespace; matches the apache.org text).
- `package.json`: `"license": "Apache-2.0"`, no `author` field.
- Headers: `SPDX-License-Identifier: Apache-2.0`, plus `Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.`
  on files derived from framework templates (`node.sh`, sync checkers, configuration scripts, tests); helper scripts
  such as `scripts/validate.sh` carry the SPDX line only.
- No `NOTICE` file, no full per-file Apache header, no licence section in the README.

## Options
1. **Apache-2.0, aligned with the community blueprints:** Apache text in `LICENSE`, SPDX headers, Amazon copyright line
   on template-derived files.
2. **Apache-2.0 with full per-file headers:** as option 1, plus the full Apache header the scanner asks for. No
   published blueprint does this; Apache-2.0 does not require it.
3. **MIT-0, matching the framework:** change `LICENSE`, `package.json` and SPDX lines to MIT-0.

## Decision
**Option 1.** `LICENSE` replaced with the Apache License 2.0 text (copied from the Avalanche blueprint, verified against
apache.org). `package.json` and the source headers already followed the convention and are unchanged. The scanner's
full-header finding is accepted as not applicable: SPDX identifiers are the ecosystem convention.

## Consequences
- `LICENSE`, `package.json` and all headers now name the same licence (Apache-2.0).
- **Publishing precondition (met 2026-11-05):** the headers name Amazon.com, Inc. as copyright holder. That is correct only if the work
  is owned by Amazon (for example, written by an Amazon employee as part of their job), and publishing it then
  follows Amazon's open-source release process. The Owner confirms this before the first public push. If the work is
  personal and not owned by Amazon, change the copyright line in the 8 headers to the actual author instead.
- If the copyright holder changes later, update the headers in one commit; the `LICENSE` text itself does not name a
  holder.
