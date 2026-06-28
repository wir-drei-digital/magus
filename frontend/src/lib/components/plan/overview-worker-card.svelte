<script lang="ts" module>
	import type { TaskPriority } from '$lib/ash/api';

	// The priority dot tint on the task line: same ladder as PriorityBadge,
	// reduced to a single pip so the line stays one calm row.
	const PRIORITY_DOT: Record<TaskPriority, string> = {
		urgent: 'bg-destructive',
		high: 'bg-warning',
		normal: 'bg-info',
		low: 'bg-muted-foreground/50'
	};
</script>

<script lang="ts">
	import { Terminal, TriangleAlert, ListChecks } from '@lucide/svelte';
	import { relativeTime } from '$lib/time';
	import { initials, agentHue } from './assignee-chip.svelte';
	import type { InFlightWorker } from './brain-overview-store.svelte';

	let {
		worker,
		planTitle
	}: {
		worker: InFlightWorker;
		/** Resolver: brainPageId → plan title (the store's `planTitle`). */
		planTitle: (brainPageId: string | null) => string;
	} = $props();

	const task = $derived(worker.primary);
	const plan = $derived(planTitle(task.brainPageId));
</script>

<!-- One worker currently on an in-progress task. An expired lease (the reaper
     will reclaim it) flips the card to an amber full border + a reclaim line. -->
<article
	data-testid="overview-worker-card"
	data-stale={worker.stale ? 'true' : undefined}
	data-worker-kind={worker.assignee.kind}
	class="flex flex-col gap-2.5 rounded-xl border bg-card/60 p-3 transition-colors hover:bg-card {worker.stale
		? 'border-warning/60'
		: 'border-border'}"
>
	<header class="flex items-start gap-2.5">
		<!-- Left icon tile, colored by worker kind. -->
		{#if worker.assignee.kind === 'external'}
			<span
				class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-orange-500/15 text-orange-600 ring-1 ring-orange-500/25 ring-inset dark:text-orange-300"
				aria-hidden="true"
			>
				<Terminal class="size-4" />
			</span>
		{:else if worker.assignee.kind === 'human'}
			<span
				class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary/15 text-xs font-semibold text-primary-link ring-1 ring-primary/25"
				aria-hidden="true"
			>
				{initials(worker.name)}
			</span>
		{:else}
			<span
				class="flex size-9 shrink-0 items-center justify-center rounded-lg text-sm font-semibold ring-1 ring-inset {agentHue(
					worker.name
				)}"
				aria-hidden="true"
			>
				{initials(worker.name)}
			</span>
		{/if}

		<div class="flex min-w-0 flex-1 flex-col">
			<span class="truncate text-sm font-semibold text-foreground" data-testid="worker-name">
				{worker.name}
			</span>
			<span class="truncate text-[11px] text-muted-foreground">{worker.typeLabel}</span>
		</div>

		{#if worker.claimedAt}
			<span class="shrink-0 text-[11px] text-muted-foreground tabular-nums">
				{relativeTime(worker.claimedAt)}
			</span>
		{/if}
	</header>

	<!-- The task they're on. -->
	<div class="flex flex-col gap-1 border-t border-border/60 pt-2">
		<p class="line-clamp-2 text-sm leading-snug font-medium text-foreground">
			{task.title}
		</p>

		{#if worker.stale}
			<p
				class="flex items-center gap-1.5 text-[11px] font-medium text-warning"
				data-testid="worker-stale"
			>
				<TriangleAlert class="size-3 shrink-0" />
				<span class="truncate">{plan} · lease expired, reclaiming</span>
			</p>
		{:else}
			<p class="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] text-muted-foreground">
				<span class="truncate font-medium text-secondary-foreground">{plan}</span>
				<span class="inline-flex items-center gap-1">
					<span class="size-1.5 rounded-full {PRIORITY_DOT[task.priority]}"></span>
					<span class="capitalize">{task.priority}</span>
				</span>
				{#if task.subtaskCount > 0}
					<span class="inline-flex items-center gap-1 tabular-nums">
						<ListChecks class="size-3 shrink-0" />
						{task.subtaskCount} subtask{task.subtaskCount === 1 ? '' : 's'}
					</span>
				{/if}
				{#if worker.tasks.length > 1}
					<span class="text-muted-foreground/70">+{worker.tasks.length - 1} more</span>
				{/if}
			</p>
		{/if}
	</div>
</article>
