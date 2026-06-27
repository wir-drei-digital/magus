# mxj5.6 — Relocate curated model catalog from core to cloud (OSS empty-start)

**Goal:** OSS first-run starts with an empty model catalog (operator adds a provider + imports models). All curated catalog data physically leaves the public `magus` repo and is owned by `magus-cloud`.

**Decisions (confirmed 2026-06-28):**
- Full relocation (data leaves OSS), not gate-only.
- OSS is fully empty, including media; admin media-options editor is a tracked follow-up (`magus-dly9`).
- `Magus.Models.Catalog` is seed/migration data only (its own moduledoc), not runtime; runtime is DB-driven via `CatalogSync`. So removing it does not affect OSS runtime.

**Why cloud-first ordering:** cloud's `seeds.exs` currently calls core `Magus.Models.Catalog.all()` and duplicates the inline `models` list (kk88 drift). If core `Catalog` is emptied first, cloud's seed silently loses 35 models. So make cloud self-sufficient first, then empty core.

**Verification gates:** OSS `mix run priv/repo/seeds.exs` on a fresh DB creates zero `Chat.Model` rows; cloud seed creates the identical catalog as today (text + media + 3 internal + metadata + default roles). `MIX_ENV=test mix compile --warnings-as-errors` clean on both. Core's 2 catalog migrations auto-no-op (empty `Catalog.all*`).

---

## Phase 1 — Cloud owns the data (magus-cloud)

### Task 1: Create `MagusCloud.Models.Catalog`
- Create `magus-cloud/lib/magus_cloud/models/catalog.ex` holding the 35 entries currently in `magus/lib/magus/models/catalog.ex` `@models` (incl. the 3 `seed?: false` internal models and all `llmdb_*` metadata blocks).
- Mirror the transformer API the seed + helpers use: `all/0`, `all_with_internal/0`, `to_db_attrs/1`, `to_llm_metadata/1`, `llmdb_provider_meta/1`. Simplest: copy the whole module, rename to `MagusCloud.Models.Catalog`, keep function bodies.
- Verify: `cd magus-cloud && MIX_ENV=test mix compile --warnings-as-errors`.

### Task 2: Point cloud seeding at the cloud catalog
- `magus-cloud/priv/repo/seeds.exs`: replace `Magus.Models.Catalog.all()` / `to_db_attrs` with `MagusCloud.Models.Catalog.*`. Keep the inline `models` list and the upsert loop and `default_role_models` as they are (cloud stays full).
- Internal models + `llm_metadata`: today these are created by core `Backfill`/`InternalizeExtras` reading core `Catalog` via migrations. With core `Catalog` about to be emptied those become no-ops, so cloud must seed them itself. Add to the cloud seed: seed `all_with_internal/0` rows (set `internal?: true`) and set `llm_metadata` from `MagusCloud.Models.Catalog.to_llm_metadata/1` inline (replicating `Backfill.backfill_llm_metadata` against the cloud catalog).
- Verify (local Docker or DB): cloud seed creates the same row count + the 3 internal rows + non-empty `llm_metadata`.

## Phase 2 — Core sheds the data (public magus)

### Task 3: Empty `Magus.Models.Catalog`
- `lib/magus/models/catalog.ex`: replace the `@models [...]` literal with `@models []`. Keep the module and all functions (generic seam; `Backfill`/`InternalizeExtras`/migrations keep compiling and no-op). Update the moduledoc: OSS ships empty; the curated catalog is owned by `MagusCloud.Models.Catalog`.

### Task 4: Trim core seeds
- `priv/repo/seeds.exs`: delete the inline `models = [...]` literal, the `catalog_models` prepend, the model upsert loop, and `default_role_models` + its loop. Keep: `require Ash.Query`, `Magus.Models.Backfill.run()` (no-op provider linking on empty DB), default library tags, usage `plans`, and the conditional `seeds_billing.exs` load.
- Add a one-line `IO.puts` noting OSS starts with an empty catalog (add a provider + import models).

### Task 5: Verify OSS empty-start
- Fresh DB: `MIX_ENV=test mix compile --warnings-as-errors`, then run seeds; assert zero `Chat.Model` rows and that the 2 catalog migrations ran without error.
- Run the model/admin test suites to confirm nothing assumed seeded models.

## Phase 3 — Close out
- Update `kk88` (cloud seed/migration drift) noting the seed duplication is partly resolved.
- Close `mxj5.6`; the cloud catalog is now the single source.
