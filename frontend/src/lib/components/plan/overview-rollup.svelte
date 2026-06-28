<script lang="ts">
	import { base } from '$app/paths';
	import { Zap, FileText, Users, Layers, ListTodo } from '@lucide/svelte';
	import { initials, agentHue, type Assignee } from './assignee-chip.svelte';
	import type { RollupMode, RollupRow } from './brain-overview-store.svelte';

	let {
		mode,
		rows,
		readyCount,
		onmode
	}: {
		mode: RollupMode;
		rows: RollupRow[];
		readyCount: number;
		onmode: (mode: RollupMode) => void;
	} = $props();

	const MODES: { key: RollupMode; label: string }[] = [
		{ key: 'plan', label: 'By plan' },
		{ key: 'assignee', label: 'By assignee' },
		{ key: 'status', label: 'By status' }
	];
</script>

<section data-testid="overview-rollup" class="flex flex-col gap-3">
	<!-- Toggle + ready pill -->
	<div class="flex flex-wrap items-center justify-between gap-2">
		<div
			class="inline-flex items-center rounded-lg border bg-card p-0.5"
			role="tablist"
			aria-label="Rollup grouping"
		>
			{#each MODES as option (option.key)}
				<button
					type="button"
					role="tab"
					aria-selected={mode === option.key}
					data-testid="rollup-mode"
					data-mode={option.key}
					data-active={mode === option.key ? 'true' : undefined}
					onclick={() => onmode(option.key)}
					class="rounded-md px-2.5 py-1 text-xs font-medium transition-colors {mode === option.key
						? 'bg-secondary text-foreground'
						: 'text-muted-foreground hover:text-foreground'}"
				>
					{option.label}
				</button>
			{/each}
		</div>

		<span
			class="inline-flex items-center gap-1.5 rounded-full bg-success/10 px-2.5 py-1 text-xs font-semibold text-success"
			data-testid="rollup-ready"
		>
			<Zap class="size-3.5" />
			<span class="tabular-nums">{readyCount}</span> ready across brain
		</span>
	</div>

	<!-- Rows -->
	<div class="flex flex-col divide-y divide-border/70 overflow-hidden rounded-xl border bg-card/40">
		{#each rows as row (row.key)}
			<div class="flex flex-col gap-2 px-3.5 py-3" data-testid="rollup-row" data-row-key={row.key}>
				<div class="flex items-center gap-2">
					<!-- Group icon per mode. -->
					{#if mode === 'plan'}
						<FileText class="size-4 shrink-0 text-primary-link" />
					{:else if mode === 'assignee'}
						<Users class="size-4 shrink-0 text-primary-link" />
					{:else}
						<Layers class="size-4 shrink-0 text-primary-link" />
					{/if}

					{#if row.brainPageId}
						<a
							href="{base}/brain/page/{row.brainPageId}"
							class="min-w-0 flex-1 truncate text-sm font-semibold text-foreground hover:underline"
						>
							{row.label}
						</a>
					{:else}
						<span class="min-w-0 flex-1 truncate text-sm font-semibold text-foreground">
							{row.label}
						</span>
					{/if}

					<span class="shrink-0 text-xs text-muted-foreground tabular-nums">
						{row.counts.total} task{row.counts.total === 1 ? '' : 's'}
					</span>
				</div>

				<!-- Status-count chips -->
				<div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-muted-foreground">
					{#if row.counts.inProgress > 0}
						<span class="inline-flex items-center gap-1.5">
							<span class="size-1.5 rounded-full bg-primary"></span>
							<span class="tabular-nums text-foreground">{row.counts.inProgress}</span> in progress
						</span>
					{/if}
					{#if row.counts.ready > 0}
						<span class="inline-flex items-center gap-1.5">
							<span class="size-1.5 rounded-full bg-success"></span>
							<span class="tabular-nums text-foreground">{row.counts.ready}</span> ready
						</span>
					{/if}
					{#if row.counts.done > 0}
						<span class="inline-flex items-center gap-1.5">
							<span class="size-1.5 rounded-full bg-success/40"></span>
							<span class="tabular-nums text-foreground">{row.counts.done}</span> done
						</span>
					{/if}
					{#if row.counts.blocked > 0}
						<span class="inline-flex items-center gap-1.5">
							<span class="size-1.5 rounded-full bg-warning"></span>
							<span class="tabular-nums text-foreground">{row.counts.blocked}</span> blocked
						</span>
					{/if}
				</div>

				<!-- Segmented progress bar + workers -->
				<div class="flex items-center gap-3">
					<div
						class="flex h-1.5 min-w-[5rem] flex-1 overflow-hidden rounded-full bg-secondary"
						role="presentation"
						data-testid="rollup-progress"
					>
						<div class="h-full bg-primary/70" style="width: {row.progress.inProgress * 100}%"></div>
						<div class="h-full bg-success" style="width: {row.progress.ready * 100}%"></div>
						<div class="h-full bg-success/40" style="width: {row.progress.done * 100}%"></div>
					</div>

					{#if row.workers.length > 0}
						<div class="flex shrink-0 items-center gap-1.5" data-testid="rollup-workers">
							<div class="flex -space-x-1.5">
								{#each row.workers.slice(0, 4) as worker, i (i)}
									{@render avatar(worker)}
								{/each}
							</div>
							<span class="text-[11px] text-muted-foreground tabular-nums">
								{row.workers.length} worker{row.workers.length === 1 ? '' : 's'}
							</span>
						</div>
					{:else}
						<span class="shrink-0 text-[11px] text-muted-foreground/70 italic">no one assigned</span
						>
					{/if}
				</div>
			</div>
		{/each}

		{#if rows.length === 0}
			<div class="flex items-center gap-2 px-3.5 py-6 text-sm text-muted-foreground">
				<ListTodo class="size-4 shrink-0 text-muted-foreground/50" />
				No tasks in this brain yet.
			</div>
		{/if}
	</div>
</section>

<!-- A compact stacked avatar; the worker's kind drives the tint (terminal-orange
     for external agents, primary for humans, the agent hue for in-app agents). -->
{#snippet avatar(worker: Assignee)}
	{#if worker.kind === 'external'}
		<span
			class="flex size-6 items-center justify-center rounded-full bg-orange-500/15 font-mono text-[9px] font-semibold text-orange-600 ring-2 ring-card dark:text-orange-300"
			title={worker.label}
		>
			{'>_'}
		</span>
	{:else if worker.kind === 'human'}
		<span
			class="flex size-6 items-center justify-center rounded-full bg-primary/15 text-[9px] font-semibold text-primary-link ring-2 ring-card"
			title={worker.self ? 'You' : worker.name}
		>
			{worker.self ? 'You' : initials(worker.name)}
		</span>
	{:else}
		<span
			class="flex size-6 items-center justify-center rounded-full text-[9px] font-semibold ring-2 ring-card {agentHue(
				worker.name
			)}"
			title={worker.name}
		>
			{initials(worker.name)}
		</span>
	{/if}
{/snippet}
