<script lang="ts">
	import { Check, ChevronUp, Sparkles, Star } from '@lucide/svelte';
	import type { ChatMode, ModelPreference, ModelSummary } from '$lib/ash/api';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import { cachedModelPreferences } from '$lib/chat/catalog';
	import { toggleFavorite } from '$lib/chat/model-preferences';
	import {
		groupModels,
		prefsById,
		FAVORITES_GROUP,
		type ModelFilters
	} from '$lib/chat/model-grouping';

	// Shared classic-style model picker: searchable, grouped by provider, mode
	// filtered. Used by both the active-conversation Composer and the new-chat
	// LandingComposer so the two stay in sync.
	let {
		models,
		chatMode,
		selectedModelId,
		onPick
	}: {
		models: ModelSummary[];
		chatMode: ChatMode;
		selectedModelId: string | null;
		onPick: (modelId: string | null) => void;
	} = $props();

	const modelLabel = $derived(models.find((model) => model.id === selectedModelId)?.name ?? 'Auto');

	let modelMenuOpen = $state(false);
	let modelQuery = $state('');
	$effect(() => {
		if (!modelMenuOpen) {
			modelQuery = '';
			favoritesOnly = false;
			showHidden = false;
		}
	});

	let prefs = $state<ModelPreference[]>([]);
	let favoritesOnly = $state(false);
	let showHidden = $state(false);

	async function loadPrefs() {
		const result = await cachedModelPreferences();
		if (result.success) prefs = result.data;
	}

	$effect(() => {
		if (modelMenuOpen) void loadPrefs();
	});

	const prefMap = $derived(prefsById(prefs));

	async function onToggleFavorite(event: MouseEvent, modelId: string, next: boolean) {
		event.preventDefault();
		event.stopPropagation();
		const updated = await toggleFavorite(modelId, next);
		if (updated) await loadPrefs();
	}

	// Only models able to produce the composer's current mode: image/video
	// generation need that output modality; everything else needs text
	// (modalities default to text when unset).
	const modeModels = $derived.by(() => {
		if (chatMode === 'image_generation') {
			return models.filter((model) => (model.outputModalities ?? []).includes('image'));
		}
		if (chatMode === 'video_generation') {
			return models.filter((model) => (model.outputModalities ?? []).includes('video'));
		}
		return models.filter((model) => (model.outputModalities ?? ['text']).includes('text'));
	});

	const groups = $derived.by(() => {
		const filters: ModelFilters = {
			search: modelQuery,
			favoritesOnly,
			showHidden,
			capability: 'any'
		};
		return groupModels(modeModels, prefMap, filters);
	});

	function formatContextWindow(tokens: number): string {
		if (tokens >= 1_000_000) return `${Math.round(tokens / 100_000) / 10}M ctx`;
		return `${Math.round(tokens / 1000)}k ctx`;
	}

	/** Modalities beyond plain text→text, rendered as tiny chips. */
	function extraModalities(model: ModelSummary): string[] {
		const inputs = (model.inputModalities ?? []).filter((entry) => entry !== 'text');
		const outputs = (model.outputModalities ?? [])
			.filter((entry) => entry !== 'text')
			.map((entry) => `→${entry}`);
		return [...inputs, ...outputs];
	}

	/** Approximate cost per request (~16k in + 4k out), from the backend estimate. */
	function requestCostLabel(cents: number | null): string | null {
		if (cents == null) return null;
		const chf = cents / 100;
		// Sub-cent estimates keep their first significant digits (0.002) instead
		// of collapsing to 0.00.
		if (chf > 0 && chf < 0.01) return `≈ CHF ${Number(chf.toPrecision(2))}`;
		return `≈ CHF ${chf.toFixed(2)}`;
	}

	// Fixed CHF-cent thresholds — keep in sync with LimitEnforcer.request_cost_tier.
	function costTierClass(cents: number | null): string {
		if (cents == null) return '';
		if (cents <= 5) return 'text-success';
		if (cents <= 20) return 'text-warning';
		return 'text-destructive';
	}

	/** Raw input/output $/M, shown in the footer next to the context window. */
	function perMillionLabel(model: ModelSummary): string | null {
		if (!model.inputCost && !model.outputCost) return null;
		return `${model.inputCost ?? '—'} / ${model.outputCost ?? '—'}`;
	}
</script>

<DropdownMenu.Root bind:open={modelMenuOpen}>
	<DropdownMenu.Trigger
		class="inline-flex items-center gap-1 rounded-lg px-2 py-1.5 text-xs font-medium text-secondary-foreground transition-colors hover:bg-accent/60 hover:text-foreground max-md:py-2.5"
		data-testid="model-selector"
	>
		<span class="max-w-36 truncate">{modelLabel}</span>
		<ChevronUp class="size-3" />
	</DropdownMenu.Trigger>
	<DropdownMenu.Content
		align="start"
		class="flex max-h-96 w-[min(24rem,calc(100vw-2rem))] flex-col gap-1 p-2"
	>
		<!-- svelte-ignore a11y_autofocus — search-first picker, classic parity -->
		<input
			type="text"
			autofocus
			placeholder="Search models..."
			bind:value={modelQuery}
			onkeydown={(event) => event.stopPropagation()}
			data-testid="model-search"
			class="mb-1 w-full rounded-lg border border-input bg-secondary px-2 py-1.5 text-xs outline-none placeholder:text-muted-foreground focus:border-primary/60"
		/>
		<div class="flex min-h-0 flex-col gap-1 overflow-y-auto">
			<DropdownMenu.Item
				onSelect={() => onPick(null)}
				class="flex-col items-start gap-0.5 rounded-lg {!selectedModelId
					? 'bg-primary/10 ring-1 ring-primary ring-inset'
					: ''}"
			>
				<span class="flex w-full items-center gap-1.5">
					<Sparkles class="size-3.5 text-primary" />
					<span class="text-xs font-medium">Auto</span>
					{#if !selectedModelId}<Check class="ml-auto size-3.5" />{/if}
				</span>
				<span class="w-full text-[10px] text-muted-foreground">
					Automatically selects the model for you
				</span>
			</DropdownMenu.Item>
			<div class="flex items-center gap-2 px-1 pb-1">
				<button
					type="button"
					onclick={(e) => {
						e.stopPropagation();
						favoritesOnly = !favoritesOnly;
					}}
					data-testid="picker-filter-favorites"
					aria-pressed={favoritesOnly}
					class="rounded px-1.5 py-0.5 text-[10px] {favoritesOnly
						? 'bg-primary/15 text-primary'
						: 'text-muted-foreground hover:bg-accent/60'}"
				>
					Favorites
				</button>
				<button
					type="button"
					onclick={(e) => {
						e.stopPropagation();
						showHidden = !showHidden;
					}}
					data-testid="picker-filter-hidden"
					aria-pressed={showHidden}
					class="rounded px-1.5 py-0.5 text-[10px] {showHidden
						? 'bg-primary/15 text-primary'
						: 'text-muted-foreground hover:bg-accent/60'}"
				>
					Show hidden
				</button>
			</div>
			{#each groups as group (group.label)}
				<p
					class="flex items-center gap-1 px-2 pt-1 font-mono text-[10px] font-medium tracking-wider text-muted-foreground uppercase"
				>
					{#if group.label === FAVORITES_GROUP}<Star class="size-3 text-primary" />{/if}
					{group.label}
				</p>
				{#each group.models as model (model.id)}
					{@const isFavorite = prefMap.get(model.id)?.favorite ?? false}
					<DropdownMenu.Item
						onSelect={() => onPick(model.id)}
						data-testid="model-option"
						class="flex-col items-start gap-0.5 rounded-lg {selectedModelId === model.id
							? 'bg-primary/10 ring-1 ring-primary ring-inset'
							: ''}"
					>
						<span class="flex w-full items-center gap-1.5">
							<button
								type="button"
								onclick={(e) => onToggleFavorite(e, model.id, !isFavorite)}
								data-testid="model-favorite-toggle"
								aria-label={isFavorite ? 'Unfavorite' : 'Favorite'}
								aria-pressed={isFavorite}
								class="shrink-0 rounded p-0.5 hover:bg-accent/60"
							>
								<Star
									class="size-3.5 {isFavorite
										? 'fill-primary text-primary'
										: 'text-muted-foreground'}"
								/>
							</button>
							<span class="truncate text-xs font-medium">{model.name}</span>
							<span class="ml-auto flex shrink-0 items-center gap-1.5">
								{#if requestCostLabel(model.requestCostCents)}
									<span
										class="text-[11px] font-medium {costTierClass(model.requestCostCents)}"
										data-testid="model-cost-estimate"
									>
										{requestCostLabel(model.requestCostCents)}
									</span>
								{/if}
								{#if selectedModelId === model.id}
									<Check class="size-3.5" />
								{/if}
							</span>
						</span>
						{#if model.shortDescription}
							<span class="line-clamp-1 w-full text-[10px] text-muted-foreground">
								{model.shortDescription}
							</span>
						{/if}
						<span class="flex w-full items-center gap-1">
							{#each extraModalities(model) as modality (modality)}
								<span class="rounded bg-secondary px-1 text-[9px] text-muted-foreground">
									{modality}
								</span>
							{/each}
							{#if model.supportsSearch}
								<span class="rounded bg-info/15 px-1 text-[9px] text-info">search</span>
							{/if}
							{#if model.supportsReasoning}
								<span class="rounded bg-primary/10 px-1 text-[9px] text-primary-link">reason</span>
							{/if}
							{#if perMillionLabel(model) || model.contextWindow}
								<span
									class="ml-auto flex items-center gap-1 text-[9px] whitespace-nowrap text-muted-foreground/70"
								>
									{#if perMillionLabel(model)}
										<span data-testid="model-cost-permillion">{perMillionLabel(model)}</span>
									{/if}
									{#if perMillionLabel(model) && model.contextWindow}
										<span aria-hidden="true">·</span>
									{/if}
									{#if model.contextWindow}
										<span>{formatContextWindow(model.contextWindow)}</span>
									{/if}
								</span>
							{/if}
						</span>
					</DropdownMenu.Item>
				{/each}
			{/each}
			{#if groups.length === 0}
				<p class="px-2 py-3 text-center text-xs text-muted-foreground" data-testid="picker-empty">
					{showHidden ? 'No matches.' : 'No models. Adjust filters or unhide in Settings.'}
				</p>
			{/if}
		</div>
	</DropdownMenu.Content>
</DropdownMenu.Root>
