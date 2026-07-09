<script lang="ts">
	import { onMount } from 'svelte';
	import { base } from '$app/paths';
	import { Section, CONTROL_CLASS } from '$lib/components/crud';
	import {
		usageLog,
		myWorkspaces,
		type UsageLog,
		type UsageLogRange,
		type WorkspaceSummary
	} from '$lib/ash/api';
	import { formatTokens } from '$lib/billing/format';

	let log = $state<UsageLog | null>(null);
	let loaded = $state(false);

	let range = $state<UsageLogRange>('current_period');
	let modelName = $state('');
	let workspace = $state('all');
	let pageNum = $state(1);

	let workspaces = $state<WorkspaceSummary[]>([]);

	// Model options come from the last successful load so the select keeps its
	// entries while a refetch is in flight (instead of collapsing to empty).
	let modelOptions = $state<string[]>([]);

	async function load() {
		loaded = false;
		const result = await usageLog({
			range,
			modelName: modelName || null,
			workspace,
			page: pageNum
		});
		if (result.success) {
			log = result.data;
			modelOptions = result.data.modelOptions;
		}
		loaded = true;
	}

	onMount(() => {
		void load();
		void myWorkspaces().then((result) => {
			if (result.success) workspaces = result.data;
		});
	});

	function applyFilters() {
		pageNum = 1;
		void load();
	}

	function goTo(target: number) {
		pageNum = Math.min(Math.max(1, target), log?.totalPages ?? 1);
		void load();
	}

	const RANGES: { value: UsageLogRange; label: string }[] = [
		{ value: 'current_period', label: 'Current period' },
		{ value: '7d', label: 'Last 7 days' },
		{ value: '30d', label: 'Last 30 days' },
		{ value: '90d', label: 'Last 90 days' },
		{ value: 'month', label: 'This month' },
		{ value: 'all', label: 'All time' }
	];

	// Server-resolved window label ("current period" resolves to the billing
	// cycle when there is one, else the last 30 days).
	const PERIOD_CAPTIONS: Record<string, string> = {
		billing_period: 'Current billing period',
		this_month: 'This month',
		all_time: 'All time',
		last_7_days: 'Last 7 days',
		last_30_days: 'Last 30 days',
		last_90_days: 'Last 90 days'
	};
	const periodCaption = $derived(
		log ? (PERIOD_CAPTIONS[log.periodLabel] ?? 'Selected period') : null
	);

	function formatChf(decimal: string): string {
		return `CHF ${decimal}`;
	}

	function formatDate(iso: string): string {
		const date = new Date(iso);
		const day = date.toLocaleDateString('en-US', {
			year: 'numeric',
			month: 'short',
			day: 'numeric'
		});
		const time = date.toLocaleTimeString(undefined, {
			hour: '2-digit',
			minute: '2-digit',
			hour12: false
		});
		return `${day}, ${time}`;
	}
</script>

<div class="flex flex-col gap-5">
	<Section
		title="Usage"
		description="Amounts shown are usage cost. See Subscription for the amount invoiced after any credit and cap."
		testid="usage-summary"
	>
		<div class="flex flex-wrap items-end gap-3">
			<label class="flex flex-col gap-1.5">
				<span class="text-xs font-medium text-muted-foreground">Time range</span>
				<select
					bind:value={range}
					onchange={applyFilters}
					data-testid="usage-filter-range"
					class={CONTROL_CLASS}
				>
					{#each RANGES as option (option.value)}
						<option value={option.value}>{option.label}</option>
					{/each}
				</select>
			</label>

			<label class="flex flex-col gap-1.5">
				<span class="text-xs font-medium text-muted-foreground">Model</span>
				<select
					bind:value={modelName}
					onchange={applyFilters}
					data-testid="usage-filter-model"
					class={CONTROL_CLASS}
				>
					<option value="">All models</option>
					{#each modelOptions as name (name)}
						<option value={name}>{name}</option>
					{/each}
				</select>
			</label>

			<label class="flex flex-col gap-1.5">
				<span class="text-xs font-medium text-muted-foreground">Workspace</span>
				<select
					bind:value={workspace}
					onchange={applyFilters}
					data-testid="usage-filter-workspace"
					class={CONTROL_CLASS}
				>
					<option value="all">All</option>
					<option value="personal">Personal</option>
					{#each workspaces as ws (ws.id)}
						<option value={ws.id}>{ws.name}</option>
					{/each}
				</select>
			</label>
		</div>

		{#if periodCaption}
			<p class="mt-3 text-xs text-muted-foreground" data-testid="usage-period-caption">
				Showing: {periodCaption}
			</p>
		{/if}

		<div class="mt-4 grid grid-cols-3 gap-6">
			<div>
				<p class="text-2xl font-bold tabular-nums" data-testid="usage-summary-tokens">
					{formatTokens(log?.summary.totalTokens ?? 0)}
				</p>
				<p class="text-xs text-muted-foreground">Total tokens</p>
			</div>
			<div>
				<p class="text-2xl font-bold tabular-nums" data-testid="usage-summary-cost">
					{formatChf(log?.summary.totalCostChf ?? '0')}
				</p>
				<p class="text-xs text-muted-foreground">Total cost</p>
			</div>
			<div>
				<p class="text-2xl font-bold tabular-nums" data-testid="usage-summary-count">
					{log?.summary.count ?? 0}
				</p>
				<p class="text-xs text-muted-foreground">Records</p>
			</div>
		</div>
	</Section>

	<Section
		title="Records"
		description="Every billable request in the selected window, newest first."
		testid="usage-records"
	>
		{#if !loaded && !log}
			<div class="space-y-2" data-testid="usage-loading">
				{#each [1, 2, 3] as i (i)}
					<div class="h-9 animate-pulse rounded-lg bg-muted/60"></div>
				{/each}
			</div>
		{:else if (log?.rows.length ?? 0) === 0}
			<p class="text-sm text-muted-foreground" data-testid="usage-empty">
				No billable usage in this period.
			</p>
		{:else if log}
			<div class="overflow-x-auto">
				<table class="w-full text-sm" data-testid="usage-table">
					<thead>
						<tr class="border-b text-left text-xs text-muted-foreground">
							<th class="py-2 pr-4 font-medium">Date</th>
							<th class="py-2 pr-4 font-medium">Model</th>
							<th class="py-2 pr-4 font-medium">Type</th>
							<th class="py-2 pr-4 text-right font-medium">Prompt</th>
							<th class="py-2 pr-4 text-right font-medium">Completion</th>
							<th class="py-2 pr-4 text-right font-medium">Tokens</th>
							<th class="py-2 pr-4 text-right font-medium">Cost</th>
							<th class="py-2"></th>
						</tr>
					</thead>
					<tbody>
						{#each log.rows as row (row.id)}
							<tr class="border-b last:border-0" data-testid="usage-row">
								<td class="whitespace-nowrap py-2 pr-4">{formatDate(row.insertedAt)}</td>
								<td class="max-w-48 truncate py-2 pr-4">{row.modelName}</td>
								<td class="py-2 pr-4">
									<span class="rounded-md bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
										{row.usageType}
									</span>
									{#if row.reconciliationStatus === 'pending'}
										<span
											class="text-xs text-amber-600 dark:text-amber-500"
											title="Provisional, awaiting reconciliation"
										>
											~
										</span>
									{/if}
								</td>
								<td class="py-2 pr-4 text-right tabular-nums">{row.promptTokens}</td>
								<td class="py-2 pr-4 text-right tabular-nums">{row.completionTokens}</td>
								<td class="py-2 pr-4 text-right tabular-nums">{row.totalTokens}</td>
								<td class="py-2 pr-4 text-right tabular-nums">{formatChf(row.costChf)}</td>
								<td class="py-2 text-right">
									{#if row.conversationId && row.messageId}
										<a
											href="{base}/chat/{row.conversationId}?highlight={row.messageId}"
											class="text-primary hover:underline"
										>
											View
										</a>
									{:else}
										<span class="text-muted-foreground/50">—</span>
									{/if}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>

			<div class="mt-3 flex items-center justify-between">
				<span class="text-xs text-muted-foreground">
					{log.totalCount}
					{log.totalCount === 1 ? 'record' : 'records'}
				</span>
				<div class="flex items-center gap-1">
					<button
						type="button"
						class="rounded-md border border-input px-2.5 py-1 text-xs font-medium transition-colors hover:bg-muted disabled:pointer-events-none disabled:opacity-50"
						data-testid="usage-page-prev"
						onclick={() => goTo(pageNum - 1)}
						disabled={!loaded || pageNum <= 1}
					>
						«
					</button>
					<span
						class="px-2 text-xs tabular-nums text-muted-foreground"
						data-testid="usage-page-indicator"
					>
						{log.page} / {log.totalPages}
					</span>
					<button
						type="button"
						class="rounded-md border border-input px-2.5 py-1 text-xs font-medium transition-colors hover:bg-muted disabled:pointer-events-none disabled:opacity-50"
						data-testid="usage-page-next"
						onclick={() => goTo(pageNum + 1)}
						disabled={!loaded || pageNum >= log.totalPages}
					>
						»
					</button>
				</div>
			</div>
		{/if}
	</Section>
</div>
