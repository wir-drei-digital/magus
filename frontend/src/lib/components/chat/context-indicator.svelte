<script lang="ts">
	import { Eraser, Combine } from '@lucide/svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import { formatTokens } from '$lib/billing/format';
	import { effectiveContextMax } from '$lib/chat/context-window';
	import type { ConversationStore } from '$lib/chat/conversation-store.svelte';
	import { confirmAction } from '$lib/stores/confirm.svelte';

	let {
		store,
		selectedContextWindow = null,
		isAuto = true
	}: {
		store: ConversationStore;
		selectedContextWindow?: number | null;
		isAuto?: boolean;
	} = $props();

	// Threshold fractions mirror the backend defaults in `Magus.Chat.ContextWindow`
	// config (config/config.exs): green < warn (0.75) <= amber < alert (0.90) <= red.
	const WARN_FRACTION = 0.75;
	const ALERT_FRACTION = 0.9;

	const snapshot = $derived(store.contextWindow);

	// SVG stroke color by band, via the semantic status tokens so the ring tracks
	// light/dark. Applied as a CSS `stroke:` property (not the SVG attribute) so
	// the var() resolves.
	const STROKE_SUCCESS = 'var(--success)';
	const STROKE_WARNING = 'var(--warning)';
	const STROKE_ERROR = 'var(--destructive)';

	const compactionStatus = $derived(snapshot?.compactionStatus ?? 'idle');
	const compacting = $derived(compactionStatus === 'pending' || compactionStatus === 'running');
	const compactFailed = $derived(compactionStatus === 'failed');

	const strategy = $derived(snapshot?.strategy ?? null);
	// With no per-conversation override the app default (config :default_strategy)
	// is in effect — surface it so the toggle shows the active strategy.
	const DEFAULT_STRATEGY = 'rolling';
	const effectiveStrategy = $derived(strategy ?? DEFAULT_STRATEGY);
	const strategyIsDefault = $derived(strategy == null);
	const breakdown = $derived(snapshot?.breakdown ?? []);
	const total = $derived(snapshot?.total ?? 0);
	// Denominator follows the selected model's window; in auto mode it falls back
	// to the snapshot max (last-used model). Declared before fill/percent below.
	const snapshotMax = $derived(snapshot?.max ?? 0);
	const max = $derived(effectiveContextMax(selectedContextWindow, snapshotMax));
	const fill = $derived(max > 0 ? Math.min(total / max, 1) : 0);
	const percent = $derived(Math.round(fill * 100));
	const strokeColor = $derived(
		fill >= ALERT_FRACTION ? STROKE_ERROR : fill >= WARN_FRACTION ? STROKE_WARNING : STROKE_SUCCESS
	);
	const modelKey = $derived(snapshot?.modelKey ?? null);

	// Provider cached-read tokens, forwarded from the ai.usage signal metadata.
	// Only shown when positive. Percent is of total input tokens (mirrors LiveView).
	const cachedTokens = $derived(snapshot?.cachedTokens ?? 0);
	const cachedPercent = $derived(total > 0 ? Math.round((cachedTokens / total) * 100) : null);

	// Breakdown rows for the panel: each category's share of the window, plus a
	// trailing "Free space" row (max − total), mirroring the reference layout.
	type BreakdownRow = { label: string; tokens: number; pct: number; free: boolean };
	const rows = $derived.by((): BreakdownRow[] => {
		// Largest categories first; the "Free space" remainder always sits last.
		const cats: BreakdownRow[] = breakdown
			.map((c) => ({
				label: c.label,
				tokens: c.tokens,
				pct: max > 0 ? (c.tokens / max) * 100 : 0,
				free: false
			}))
			.sort((a, b) => b.tokens - a.tokens);
		if (max > 0) {
			const freeTokens = Math.max(0, max - total);
			cats.push({
				label: 'Free space',
				tokens: freeTokens,
				pct: (freeTokens / max) * 100,
				free: true
			});
		}
		return cats;
	});

	const compactTitle = $derived(
		compactionStatus === 'running'
			? 'Compacting…'
			: compactionStatus === 'pending'
				? 'Compaction queued…'
				: compactionStatus === 'failed'
					? 'Compaction failed: retry'
					: 'Summarize older messages to free up the window'
	);

	async function clear() {
		// Locked mid-compaction (same guard as compact()): a Clear committed while a
		// pass is in flight would be silently clobbered by the in-flight summary +
		// pointer write (lost update).
		if (compacting) return;
		const ok = await confirmAction({
			title: 'Clear context window?',
			description: "Older messages stay in the transcript but won't be sent to the model.",
			confirmLabel: 'Clear'
		});
		if (ok) void store.clearContext();
	}

	function compact() {
		if (compacting) return;
		void store.compactContext();
	}

	function pickStrategy(next: 'rolling' | 'compact') {
		// Toggle off the override when re-selecting the active one.
		void store.setContextStrategy(strategy === next ? null : next);
	}
</script>

{#if snapshot}
	<DropdownMenu.Root>
		<DropdownMenu.Trigger
			class="inline-flex size-8 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-accent hover:text-foreground max-md:size-10"
			aria-label="Context window"
			title="Context window"
			data-testid="context-indicator"
			data-context-fill={fill.toFixed(3)}
		>
			<svg viewBox="0 0 36 36" class="size-3.5 -rotate-90">
				<circle
					cx="18"
					cy="18"
					r="15.9155"
					fill="none"
					class="stroke-muted-foreground/50"
					stroke-width="4"
				/>
				<circle
					cx="18"
					cy="18"
					r="15.9155"
					fill="none"
					stroke-width="4"
					stroke-linecap="round"
					style="stroke: {strokeColor}"
					stroke-dasharray="{(fill * 100).toFixed(1)} 100"
				/>
			</svg>
		</DropdownMenu.Trigger>
		<DropdownMenu.Content side="top" align="end" class="w-72 p-3">
			<!-- Header: title + total/max/percent (reference layout). -->
			<div class="flex items-baseline justify-between gap-2">
				<span class="text-xs font-semibold">Context window</span>
				<span class="text-xs tabular-nums text-muted-foreground" data-testid="context-total">
					{formatTokens(total)} / {formatTokens(max)} ({percent}%)
				</span>
			</div>
			{#if isAuto && modelKey}
				<p
					class="mt-0.5 truncate text-[11px] text-muted-foreground"
					title={modelKey}
					data-testid="context-model"
				>
					via {modelKey}
				</p>
			{/if}

			<!-- Fill bar, colored by the same band as the donut. -->
			<div class="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-muted">
				<div
					class="h-full rounded-full transition-[width]"
					style="width: {Math.min(100, percent)}%; background-color: {strokeColor}"
				></div>
			</div>

			{#if cachedTokens > 0}
				<p
					class="mt-1.5 text-[11px] text-muted-foreground"
					data-testid="context-cached"
					data-role="context-cached"
				>
					{formatTokens(cachedTokens)} from cache{cachedPercent !== null
						? ` (${cachedPercent}%)`
						: ''}
				</p>
			{/if}

			<!-- Breakdown: label, then right-aligned tokens + percent. -->
			<ul class="mt-2.5 space-y-1" data-testid="context-breakdown">
				{#if breakdown.length === 0}
					<li class="text-xs text-muted-foreground">No breakdown yet.</li>
				{:else}
					{#each rows as row (row.label)}
						<li class="flex items-center gap-2 text-xs">
							<span class="flex-1 truncate {row.free ? 'text-muted-foreground' : ''}"
								>{row.label}</span
							>
							<span class="tabular-nums text-muted-foreground">{formatTokens(row.tokens)}</span>
							<span class="w-11 text-right tabular-nums text-muted-foreground"
								>{row.pct.toFixed(1)}%</span
							>
						</li>
					{/each}
				{/if}
			</ul>

			<!-- One row: strategy toggle (config) on the left, icon actions on the
			     right. The effective strategy is highlighted — the app default when
			     there's no per-conversation override. -->
			<div class="mt-3 flex items-center gap-2 border-t border-border pt-3">
				<div class="flex overflow-hidden rounded-md border border-border">
					<button
						type="button"
						data-testid="context-strategy-rolling"
						onclick={() => pickStrategy('rolling')}
						title={strategyIsDefault && effectiveStrategy === 'rolling'
							? 'Active by default'
							: undefined}
						class="px-2.5 py-1 text-xs transition-colors {effectiveStrategy === 'rolling'
							? 'bg-primary text-primary-foreground'
							: 'hover:bg-accent'}"
					>
						Rolling
					</button>
					<button
						type="button"
						data-testid="context-strategy-compact"
						onclick={() => pickStrategy('compact')}
						title={strategyIsDefault && effectiveStrategy === 'compact'
							? 'Active by default'
							: undefined}
						class="border-l border-border px-2.5 py-1 text-xs transition-colors {effectiveStrategy ===
						'compact'
							? 'bg-primary text-primary-foreground'
							: 'hover:bg-accent'}"
					>
						Auto compact
					</button>
				</div>

				<div class="flex-1"></div>

				<button
					type="button"
					data-testid="context-compact"
					data-compaction-status={compactionStatus}
					onclick={compact}
					disabled={compacting}
					title={compactTitle}
					aria-label={compactFailed ? 'Retry compaction' : 'Compact now'}
					class="flex size-7 shrink-0 items-center justify-center rounded-md border border-border transition-colors hover:bg-accent disabled:cursor-not-allowed disabled:opacity-60"
				>
					{#if compacting}
						<span
							class="size-3 animate-spin rounded-full border-2 border-current border-t-transparent"
						></span>
					{:else}
						<Combine class="size-3.5" />
					{/if}
				</button>

				<button
					type="button"
					data-testid="context-clear"
					onclick={clear}
					disabled={compacting}
					title="Clear"
					aria-label="Clear context"
					class="flex size-7 shrink-0 items-center justify-center rounded-md border border-border text-muted-foreground transition-colors hover:bg-accent hover:text-foreground disabled:cursor-not-allowed disabled:opacity-60"
				>
					<Eraser class="size-3.5" />
				</button>
			</div>

			<a
				href="/docs/conversations/context-window"
				data-sveltekit-reload
				class="mt-2 block text-[11px] text-muted-foreground transition-colors hover:text-foreground hover:underline"
			>
				Learn about context strategies
			</a>
		</DropdownMenu.Content>
	</DropdownMenu.Root>
{/if}
