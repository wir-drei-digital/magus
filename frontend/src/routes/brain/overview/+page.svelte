<script lang="ts">
	import { page } from '$app/state';
	import { untrack } from 'svelte';
	import { Brain, Radio, Users2 } from '@lucide/svelte';
	import { brainNav } from '$lib/stores/brain-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { relativeTime } from '$lib/time';
	import {
		BrainOverviewStore,
		type RollupMode
	} from '$lib/components/plan/brain-overview-store.svelte';
	import { joinBrainTasks } from '$lib/realtime/task-updates';
	import OverviewWorkerCard from '$lib/components/plan/overview-worker-card.svelte';
	import OverviewRollup from '$lib/components/plan/overview-rollup.svelte';
	import OverviewStranded from '$lib/components/plan/overview-stranded.svelte';
	import PlanTree from '$lib/components/plan/plan-tree.svelte';
	import ActivityFeed from '$lib/components/plan/activity-feed.svelte';
	import { ListTree } from '@lucide/svelte';

	// Which brain the overview shows:
	//   1. an explicit ?brain=<id> (e.g. the nav's per-brain Overview link), else
	//   2. the first brain in the loaded nav (the same brain the nav auto-expands
	//      for orientation).
	// Brains load through the shared brain-nav store; we trigger that load here so
	// the overview is reachable directly (deep link / refresh) without the nav
	// pane having mounted first.
	const paramBrainId = $derived(page.url.searchParams.get('brain'));
	const brainId = $derived(paramBrainId ?? brainNav.brains[0]?.id ?? null);

	$effect(() => {
		void brainNav.load(session.user?.currentWorkspaceId ?? null);
	});

	// One-shot: a deep link to the overview syncs the mode strip to brain once.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'brain') void workbench.setMode('brain');
	});

	// One store per brain; re-created when the resolved brain id changes.
	let store = $state<BrainOverviewStore | null>(null);
	let loadedAt = $state<string | null>(null);

	$effect(() => {
		const id = brainId;
		if (!id) {
			store = null;
			return;
		}
		const next = untrack(() => new BrainOverviewStore(id));
		store = next;
		void next.load().then(() => {
			if (store === next) loadedAt = new Date().toISOString();
		});
	});

	// Live updates: any task.* across this brain (other clients / agents) refreshes
	// the in-flight / rollup / activity regions. Refetch on each event (the store's
	// derivations are cheap); re-stamp "updated" so the freshness label tracks it.
	// Re-subscribes when the brain id changes; leaves on unmount.
	$effect(() => {
		const id = brainId;
		if (!id) return;

		let cancelled = false;
		let leave: (() => void) | null = null;

		void joinBrainTasks(id, () => {
			const current = store;
			if (current?.brainId !== id) return;
			void current.reload().then(() => {
				if (store === current) loadedAt = new Date().toISOString();
			});
		}).then((cleanup) => {
			if (cancelled) cleanup();
			else leave = cleanup;
		});

		return () => {
			cancelled = true;
			leave?.();
		};
	});

	const brainTitle = $derived(brainNav.brains.find((b) => b.id === brainId)?.title ?? 'Brain');

	function setMode(mode: RollupMode) {
		if (store) store.rollupMode = mode;
	}

	// Re-stamp the "updated" label every 30s so it ages without a manual refresh.
	let tick = $state(0);
	$effect(() => {
		const handle = setInterval(() => (tick += 1), 30_000);
		return () => clearInterval(handle);
	});
	const updatedLabel = $derived.by(() => {
		void tick;
		return loadedAt ? relativeTime(loadedAt) : 'just now';
	});
</script>

<svelte:head>
	<title>Magus — Brain Overview</title>
</svelte:head>

<div class="flex h-full min-h-0 flex-col bg-background" data-testid="brain-overview">
	{#if !brainId}
		<div class="flex h-full flex-col items-center justify-center gap-2 p-6 text-center">
			<Brain class="size-8 text-muted-foreground/50" />
			<p class="text-sm text-muted-foreground">
				{brainNav.loading ? 'Loading brains…' : 'Create a brain to see its overview.'}
			</p>
		</div>
	{:else if store}
		<!-- ── Header ─────────────────────────────────────────────────────── -->
		<header
			class="flex shrink-0 flex-wrap items-center gap-x-3 gap-y-2 border-b bg-background/80 py-3.5 pr-6 pl-14 backdrop-blur-sm md:pl-6"
		>
			<div class="flex min-w-0 flex-col gap-0.5">
				<div class="flex items-center gap-2">
					<Brain class="size-5 shrink-0 text-primary-link" />
					<h1 class="truncate text-lg font-semibold text-foreground">Brain Overview</h1>
					<span
						class="rounded-full border border-border bg-secondary px-2 py-0.5 text-[10px] font-medium tracking-wide text-muted-foreground uppercase"
					>
						read-only
					</span>
				</div>
				<p
					class="flex flex-wrap items-center gap-x-2 gap-y-0.5 pl-7 text-xs text-muted-foreground"
					data-testid="overview-subline"
				>
					<span class="font-medium text-secondary-foreground">{brainTitle}</span>
					<span aria-hidden="true">·</span>
					<span><span class="tabular-nums text-foreground">{store.planCount}</span> plans</span>
					<span aria-hidden="true">·</span>
					<span
						><span class="tabular-nums text-foreground">{store.inFlightCount}</span> in flight</span
					>
					<span aria-hidden="true">·</span>
					<span
						><span class="tabular-nums text-foreground">{store.readyCount}</span> ready to grab</span
					>
					{#if store.strandedCount > 0}
						<span aria-hidden="true">·</span>
						<span class="font-medium text-warning" data-testid="overview-stranded-summary">
							<span class="tabular-nums">{store.strandedCount}</span> need delivery
						</span>
					{/if}
					<span aria-hidden="true">·</span>
					<span>updated {updatedLabel}</span>
				</p>
			</div>

			<span
				class="ml-auto inline-flex shrink-0 items-center gap-1.5 rounded-full bg-success/10 px-2.5 py-1 text-xs font-semibold text-success"
			>
				<Radio class="size-3.5" />
				<span class="size-1.5 animate-pulse rounded-full bg-success"></span>
				live
			</span>
		</header>

		{#if store.loading && store.tasks.length === 0}
			<p class="p-6 text-sm text-muted-foreground">Loading overview…</p>
		{:else if store.loadError}
			<p class="p-6 text-sm text-destructive">{store.loadError}</p>
		{:else}
			<!-- ── Body: main column (in-flight + rollup) + activity rail ────── -->
			<div
				class="grid min-h-0 flex-1 grid-cols-1 gap-6 overflow-y-auto p-6 lg:grid-cols-[1fr_22rem]"
			>
				<div class="flex min-w-0 flex-col gap-8">
					<!-- NEEDS DELIVERY (anti-stranding alarm): renders only when non-empty -->
					<OverviewStranded
						plans={store.strandedPlans}
						pending={store.deliverPending}
						onDeliver={(id, ref) => void store!.markDelivered(id, ref)}
					/>

					<!-- IN FLIGHT -->
					<section data-testid="overview-in-flight" class="flex flex-col gap-3">
						<div class="flex items-center gap-2">
							<Users2 class="size-4 shrink-0 text-primary-link" />
							<h2 class="text-sm font-semibold tracking-wide text-foreground uppercase">
								In flight
							</h2>
							<span class="text-xs text-muted-foreground">
								{store.inFlightCount} worker{store.inFlightCount === 1 ? '' : 's'} active now
							</span>
						</div>

						{#if store.inFlight.length === 0}
							<div
								class="rounded-xl border border-dashed border-border/70 px-4 py-8 text-center text-sm text-muted-foreground"
								data-testid="overview-in-flight-empty"
							>
								No workers active right now. Ready work can be claimed from any plan.
							</div>
						{:else}
							<div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
								{#each store.inFlight as worker (worker.key)}
									<OverviewWorkerCard {worker} planTitle={(id) => store!.planTitle(id)} />
								{/each}
							</div>
						{/if}
					</section>

					<!-- ROLLUP -->
					<OverviewRollup
						mode={store.rollupMode}
						rows={store.rollup}
						readyCount={store.readyCount}
						onmode={setMode}
					/>

					<!-- PLAN STRUCTURE (unified spec -> plan -> phases -> tasks tree) -->
					<section data-testid="overview-plan-tree" class="flex flex-col gap-3">
						<div class="flex items-center gap-2">
							<ListTree class="size-4 shrink-0 text-primary-link" />
							<h2 class="text-sm font-semibold tracking-wide text-foreground uppercase">
								Plan structure
							</h2>
							<span class="text-xs text-muted-foreground">spec to plan to phases</span>
						</div>
						<PlanTree
							tree={store.tree}
							pending={store.deliverPending}
							onDeliver={(id, ref) => void store!.markDelivered(id, ref)}
							onUndeliver={(id) => void store!.undeliver(id)}
						/>
					</section>
				</div>

				<!-- ACTIVITY rail -->
				<aside class="flex min-h-0 min-w-0 flex-col lg:border-l lg:border-border lg:pl-6">
					<ActivityFeed entries={store.activity} />
				</aside>
			</div>
		{/if}
	{/if}
</div>
