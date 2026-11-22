# AGENTS.md trim: offline acceptance audit (test-1 narrowed scope)

Scope: three offline-checkable scenarios from the test-1 fix directive. The live firstmate primary session is out of scope and was not driven.

Worktree target: de0cdefe (`docs: trim AGENTS.md by about a fifth without dropping a boundary`), base 427056c4.

## Size

| file | base 427056c4 | trimmed de0cdefe |
|---|---|---|
| AGENTS.md bytes | 51560 | 40044 (-11516 bytes, -22.3%) |

## Scenario 1: section references still point at the same topic

- Section headings: the 14 section titles and all `###` subsection titles are identical to base, in the same order (numbers stripped, diff empty).
- 131 `section N` / `§N` references across `bin/`, `.agents/skills/`, `docs/`, `tests/` were reviewed against the trimmed file. No reference lost its topic because of the trim.
- Path and link resolution over trimmed AGENTS.md: 52 names checked (repo paths, markdown link targets, skill names), 0 missing. Base: 54 checked, 0 missing.
- Pre-existing stale pointers, not caused by the trim, fixed in this change:
  - `.agents/skills/fmx-respond/SKILL.md`: "AGENTS.md §13 declares the load trigger for Relay-linked wakes". The trigger is in §8 (base and trimmed). Now says §8.
  - `.agents/skills/bootstrap-diagnostics/SKILL.md`: "AGENTS.md section 8 explains why this guard exists". §8 never explained the tangle guard. Now says §8 requires resolving the warning without touching unlanded work.
  - `.agents/skills/captain-hold-lifecycle/SKILL.md`: "Captain's Call section under AGENTS.md section 9". The Captain's Call is a Bearings board element. Now says captain-facing terms of §9.
  - `bin/backends/tmux.sh` header: removed the "AGENTS.md section 8" citation for "Reference backend", which §8 does not cover.
- Pre-existing, left as-is (not trim-related; comment-level): `bin/backends/herdr.sh:3991` cites §8 for "immediate blocked-state escalation"; §8 covers wake handling, not that mechanism. `docs/supervision-protocols/pi.md:32` cites "the dim anchor" in §9; §9 (captain-facing merge ask must carry the full URL) still carries the rule, the phrase is not in base either.

## Scenario 2: safety boundaries still stated in trimmed AGENTS.md

| boundary | trimmed AGENTS.md line |
|---|---|
| never write to projects | 25-29 (hard rule 1) |
| no merge without captain's explicit word | 30-31 (hard rule 2) |
| never tear down unlanded work | 32-35 (hard rule 3) |
| crewmates never address the captain | 12, 36-38 (hard rule 4) |
| no broad pkill of watchers | 247 |
| fm-send never for lifecycle control | 180 |
| isolated worktree for ships | 172 (spawn), 329 (ship brief assertion) |

## Scenario 3: quota-array-dispatch states the moved selection rules in full

Checked in `.agents/skills/quota-array-dispatch/SKILL.md`:

- uncertainty vs ineligibility: lines 100-106 (disclosed uncertainty keeps a candidate eligible; only concrete contradictory evidence blocks).
- ties: lines 158-160 (stop and report tied candidates; never by array order or harness name; duplicates are a config error).
- malformed config: line 114 (actionable error, not ranked around); line 26 (non-boolean `shared_quota` is an actionable error).
- every-candidate accounting: line 162.
- The skill's own header (line 14) says it states the three rules in full; that is now true.

## Tests run (targeted, from the worktree)

- `tests/fm-backend-tmux-smoke.test.sh` rc=0
- `tests/fm-backend.test.sh` rc=0
- `tests/fm-tangle-guard.test.sh` rc=0
- `tests/fm-tmux-agent-liveness.test.sh` rc=0
- `tests/fm-tmux-submit-busy.test.sh` rc=0
- `tests/fm-documentation-audiences.test.sh` rc=0
- `tests/fm-ensure-agents-md.test.sh` rc=0
- `tests/fm-captain-hold-lifecycle.test.sh` rc=0 (elapsed 421s, 68 ok, 0 not ok; first attempt was cut by a 300s wrapper timeout with 39 ok and no failures).
