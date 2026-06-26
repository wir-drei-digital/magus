<script lang="ts">
	import { onDestroy, onMount } from 'svelte';
	import {
		conversationSettings,
		resetConversationSettings,
		updateConversationSettings,
		type SamplingSettings
	} from '$lib/ash/api';

	let { conversationId }: { conversationId: string } = $props();

	let loading = $state(true);
	let error = $state<string | null>(null);

	// Form state as strings so cleared inputs mean "unset" (classic parity:
	// only non-empty values are written; an all-empty map becomes null).
	let systemPrompt = $state('');
	let temperature = $state('');
	let maxTokens = $state('');
	let topP = $state('');
	let topK = $state('');

	onMount(() => {
		void conversationSettings(conversationId).then((result) => {
			if (result.success) {
				systemPrompt = result.data.systemPrompt ?? '';
				const sampling = result.data.samplingSettings ?? {};
				temperature = sampling.temperature?.toString() ?? '';
				maxTokens = sampling.max_tokens?.toString() ?? '';
				topP = sampling.top_p?.toString() ?? '';
				topK = sampling.top_k?.toString() ?? '';
			}
			loading = false;
		});
	});

	let saveTimer: ReturnType<typeof setTimeout> | null = null;

	function queueSave() {
		if (saveTimer) clearTimeout(saveTimer);
		saveTimer = setTimeout(() => void save(), 500);
	}

	// Closing the popover destroys the panel; flush a pending debounced save so
	// the last keystrokes aren't lost. The loading guard prevents a race where
	// an immediate close would write empty values before the load resolved.
	onDestroy(() => {
		if (saveTimer && !loading) {
			clearTimeout(saveTimer);
			void save();
		}
	});

	async function save() {
		error = null;
		const sampling: SamplingSettings = {};
		const parsedTemperature = parseFloat(temperature);
		const parsedMaxTokens = parseInt(maxTokens, 10);
		const parsedTopP = parseFloat(topP);
		const parsedTopK = parseInt(topK, 10);
		if (!Number.isNaN(parsedTemperature)) sampling.temperature = parsedTemperature;
		if (!Number.isNaN(parsedMaxTokens)) sampling.max_tokens = parsedMaxTokens;
		if (!Number.isNaN(parsedTopP)) sampling.top_p = parsedTopP;
		if (!Number.isNaN(parsedTopK)) sampling.top_k = parsedTopK;

		const result = await updateConversationSettings(conversationId, {
			systemPrompt: systemPrompt.trim() === '' ? null : systemPrompt,
			samplingSettings: Object.keys(sampling).length === 0 ? null : sampling
		});
		if (!result.success) error = result.errors[0]?.message ?? 'Could not save settings';
	}

	async function reset() {
		if (saveTimer) clearTimeout(saveTimer);
		error = null;
		const result = await resetConversationSettings(conversationId);
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Could not reset settings';
			return;
		}
		systemPrompt = '';
		temperature = '';
		maxTokens = '';
		topP = '';
		topK = '';
	}
</script>

{#snippet numberField(
	label: string,
	hint: string,
	value: string,
	set: (next: string) => void,
	min: number,
	max: number,
	step: number | 'any'
)}
	<label class="block">
		<span class="flex items-baseline justify-between text-xs">
			<span class="font-medium">{label}</span>
			<span class="text-[10px] text-muted-foreground">{hint}</span>
		</span>
		<input
			type="number"
			{min}
			{max}
			{step}
			{value}
			oninput={(event) => {
				set(event.currentTarget.value);
				queueSave();
			}}
			class="mt-1 w-full rounded-md border border-input bg-secondary px-2 py-1.5 text-xs outline-none focus:border-primary/60"
		/>
	</label>
{/snippet}

<div class="flex min-h-0 flex-1 flex-col" data-testid="rail-settings-panel">
	<div class="wb-scroll min-h-0 flex-1 space-y-3 overflow-y-auto p-3">
		{#if loading}
			<div class="space-y-2">
				{#each [1, 2, 3] as i (i)}
					<div class="h-10 animate-pulse rounded-md bg-muted"></div>
				{/each}
			</div>
		{:else}
			{#if error}
				<p class="text-xs text-destructive">{error}</p>
			{/if}

			<label class="block">
				<span class="text-xs font-medium">System prompt</span>
				<textarea
					bind:value={systemPrompt}
					oninput={queueSave}
					rows="5"
					placeholder="Custom instructions for the AI…"
					data-testid="rail-system-prompt"
					class="mt-1 w-full resize-none rounded-md border border-input bg-secondary px-2 py-1.5 text-xs outline-none focus:border-primary/60"
				></textarea>
			</label>

			<p class="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
				Sampling
			</p>
			<div class="grid grid-cols-2 gap-2.5">
				{@render numberField(
					'Temperature',
					'0–2 · rec. 0.7–1.0',
					temperature,
					(next) => (temperature = next),
					0,
					2,
					0.1
				)}
				{@render numberField(
					'Max tokens',
					'1–128000',
					maxTokens,
					(next) => (maxTokens = next),
					1,
					128000,
					1
				)}
				{@render numberField(
					'Top P',
					'0–1 · rec. 0.9–1.0',
					topP,
					(next) => (topP = next),
					0,
					1,
					0.05
				)}
				{@render numberField(
					'Top K',
					'1–100 · rec. 40–100',
					topK,
					(next) => (topK = next),
					1,
					100,
					1
				)}
			</div>

			<button
				type="button"
				class="rounded-md border border-input px-2.5 py-1.5 text-xs text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
				data-testid="rail-reset-settings"
				onclick={() => void reset()}
			>
				Reset to defaults
			</button>
		{/if}
	</div>
</div>
