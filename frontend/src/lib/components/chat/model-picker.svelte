<script lang="ts">
	import { Check, ChevronUp, Sparkles } from '@lucide/svelte';
	import type { ChatMode, ModelSummary } from '$lib/ash/api';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';

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
		if (!modelMenuOpen) modelQuery = '';
	});

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

	const modelsByProvider = $derived.by(() => {
		const query = modelQuery.toLowerCase();
		const grouped = new Map<string, ModelSummary[]>();
		for (const model of modeModels) {
			if (
				query !== '' &&
				!model.name.toLowerCase().includes(query) &&
				!(model.provider ?? '').toLowerCase().includes(query)
			) {
				continue;
			}
			const key = model.provider ?? 'Other';
			grouped.set(key, [...(grouped.get(key) ?? []), model]);
		}
		return [...grouped.entries()];
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
		return `≈ CHF ${(cents / 100).toFixed(2)}`;
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
	<DropdownMenu.Content align="start" class="flex max-h-96 w-[min(24rem,calc(100vw-2rem))] flex-col gap-1 p-2">
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
			{#each modelsByProvider as [provider, providerModels] (provider)}
				<p class="px-2 pt-1 font-mono text-[10px] font-medium tracking-wider text-muted-foreground uppercase">
					{provider}
				</p>
				{#each providerModels as model (model.id)}
					<DropdownMenu.Item
						onSelect={() => onPick(model.id)}
						data-testid="model-option"
						class="flex-col items-start gap-0.5 rounded-lg {selectedModelId === model.id
							? 'bg-primary/10 ring-1 ring-primary ring-inset'
							: ''}"
					>
						<span class="flex w-full items-center gap-1.5">
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
			{#if modelsByProvider.length === 0}
				<p class="px-2 py-3 text-center text-xs text-muted-foreground">No matches.</p>
			{/if}
		</div>
	</DropdownMenu.Content>
</DropdownMenu.Root>
