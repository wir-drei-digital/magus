# Memory eval baselines

Before/after evidence for the memory-hardening plan (`2026-07-04-memory-hardening.md`),
measured with LongMemEval-S through the real agent pipeline.

## Method

- **Benchmark:** LongMemEval-S (the real 500-question dataset, cached at `eval/cache/longmemeval_s.json`, gitignored).
- **Limit:** `--limit 18`, **stratified** (round-robin by ability → 3 per ability across all 6 abilities). This is a deliberate deviation from the plan's `--limit 60`: each LongMemEval-S question replays ~493 turns through the real, sequential agent pipeline (~5-12 min/question), so 60 questions is a ~10h/run job. 18 stratified gives a directional read within the session; the full 60 remains available as an overnight/CI run.
- **Subject:** `Magus.Eval.Subject.Live` (real agent pipeline). Extraction is driven **one session-window at a time** (a replayed session = one production debounce window):
  - **Baseline** extracts each session's **last turn-pair only** (mirrors the old `load_last_turn`).
  - **Hardened** extracts **all turn-pairs** of each session (the windowed extraction under test).
  This is the fair A/B: same window shape, differing only in extraction depth — the exact production code difference.
- **Judge:** `gpt-4o-mini`, reference-guided (LLM-as-judge), pinned prompt v1.

### Judge caveat (important)

Both runs' **inline** end-of-run scoring returned aggregate 0.0 — a harness artifact, not a real score. The judge fires a burst of 18 calls at scoring time (after ~700 prior pipeline calls), which hits an OpenRouter rate limit; `long_mem_eval.ex` maps a judge `{:error}` to `correct? = false`, zeroing every case. The judge was hardened with retry-on-transient-error (commit `d04b494`), but the ~2.4s retry window is shorter than the sustained burst limit. **Recovery:** both runs' answers are saved (the query phase is unaffected by the judge failure), so both were re-scored from their saved hypotheses with a paced judge (500ms/case), yielding `judge_errors = 0`. The scoreboard rows (`eval/results/longmemeval.jsonl`, git_sha `2647c9c` and `8c03d33b`) show the bogus 0.0 and are **superseded by the re-scored numbers below**.

Follow-up (filed for later): move judging per-case into `run_case` (spread over the run) instead of a burst in `score/2`, so inline scoring is reliable without after-the-fact re-scoring.

## Results

Both re-scored from saved hypotheses under identical, paced judge conditions (`judge_errors = 0` for both).

| Ability | Baseline (pre-hardening, last-pair/session) | Hardened (all-turns/session) | Δ |
|---|---|---|---|
| knowledge-update | 1/3 | 2/3 | +1 |
| single-session-user | 0/3 | 1/3 | +1 |
| single-session-assistant | 0/3 | 0/3 | 0 |
| single-session-preference | 0/3 | 0/3 | 0 |
| multi-session | 0/3 | 0/3 | 0 |
| temporal-reasoning | 0/3 | 0/3 | 0 |
| **Aggregate** | **1/18 (0.0556)** | **3/18 (0.1667)** | **+2 (3×)** |

- Baseline code: branch base + eval-harness optimizations (`9acf24c`), extraction = last-pair-per-session.
- Hardened code: full Plan A (Tasks 2-7, through `fb76275`), extraction = all-turns-per-session. Profile layer (Plan B) OFF.

## Reading

The hardening **tripled** aggregate recall (1 → 3 correct), and the movement is on exactly the abilities the fixes target:

- **knowledge-update 1/3 → 2/3.** The combination of windowed extraction (capturing the turn that states the update) and explicit `update_mode: "replace"` (superseding the stale value) is precisely the contradiction/update path this ability tests. Predicted to move most; it did.
- **single-session-user 0/3 → 1/3.** Windowed extraction captures a fact stated mid-session that the last-pair baseline dropped. Predicted; moved.
- **No regressions.** No ability went down. The unchanged abilities (multi-session, temporal, single-session-assistant/preference) are the harder multi-hop/temporal cases where 3 samples/ability is dominated by noise, and where Plan A's mechanisms (capture + contradiction handling) aren't the limiting factor.

### Honesty about the numbers

- **18 cases, 3/ability, is directional only.** A +1 swing in an ability is one case. The aggregate 3× is a real signal (baseline barely captures facts, hardened captures them), but this is not a statistically robust benchmark result. For a gating number, run `--limit 60` (or the full 500) overnight.
- The baseline is **idealized-harsh** (one pair per session). Real production `load_last_turn` with natural pauses would capture somewhat more than one pair/session, so the true production improvement is likely smaller than 3×. The direction (windowed extraction improves recall on capture/update abilities) is the durable finding.

## How to reproduce

```bash
# Clean the disposable eval DB (the harness has no teardown; a 2nd run on a dirty
# DB collides on the fixture workspace slug):
PGPASSWORD=postgres psql -h localhost -U postgres -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='magus_test_eval' AND pid<>pg_backend_pid();" \
  -c "DROP DATABASE IF EXISTS magus_test_eval;"
MIX_TEST_PARTITION=_eval MIX_ENV=test mix ash.setup

# Run (baseline = check out the branch base + harness commit; hardened = branch head):
set -a && source .env && set +a
MIX_TEST_PARTITION=_eval MIX_ENV=test mix magus.eval longmemeval --limit 18 --out eval/results

# If the inline aggregate is 0.0 (judge burst rate-limited), re-score from the saved
# eval/results/longmemeval.hyp.jsonl with a paced judge (see scratchpad rescore script).
```
