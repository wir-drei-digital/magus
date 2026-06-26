<script lang="ts">
	import { Sparkles, ScrollText, Star } from '@lucide/svelte';
	import type { PromptSummary } from '$lib/ash/api';

	let {
		prompt,
		href,
		selected = false,
		compact = false,
		onToggleFavorite
	}: {
		prompt: PromptSummary;
		href: string;
		selected?: boolean;
		compact?: boolean;
		onToggleFavorite?: (prompt: PromptSummary) => void;
	} = $props();

	// The first lines of the body double as a preview: the whole point of the
	// gallery is seeing what is inside a prompt, not just its name.
	const preview = $derived(prompt.content.trim());
</script>

<!-- The card itself is the link (whole-surface navigation); the favorite button
     is a sibling overlaid in the corner so we avoid a button nested in an anchor. -->
<div class="group/card relative">
	<a
		{href}
		data-testid="prompt-card"
		data-selected={selected ? 'true' : undefined}
		class="flex h-full flex-col gap-2 rounded-xl border bg-card/50 p-3.5 transition-colors hover:border-primary/40 hover:bg-card focus-visible:border-primary/60 focus-visible:ring-2 focus-visible:ring-primary/50 focus-visible:outline-none {selected
			? 'border-primary/60 bg-card'
			: 'border-border'}"
	>
		<div class="flex items-start gap-2 pr-5">
			{#if prompt.type === 'system'}
				<Sparkles class="mt-0.5 size-4 shrink-0 text-primary" />
			{:else}
				<ScrollText class="mt-0.5 size-4 shrink-0 text-muted-foreground" />
			{/if}
			<div class="min-w-0 flex-1">
				<p class="truncate text-sm font-medium">{prompt.name}</p>
				{#if prompt.description && !compact}
					<p class="truncate text-xs text-muted-foreground">{prompt.description}</p>
				{/if}
			</div>
		</div>

		{#if preview}
			<p
				class="font-mono text-xs leading-relaxed text-muted-foreground {compact
					? 'line-clamp-2'
					: 'line-clamp-3'}"
			>
				{preview}
			</p>
		{/if}

		<div class="mt-auto flex items-center gap-1.5 pt-0.5">
			{#each prompt.tags.slice(0, compact ? 1 : 2) as tag (tag.id)}
				<span class="rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-primary"
					>#{tag.name}</span
				>
			{/each}
			<span class="ml-auto shrink-0 text-[10px] text-muted-foreground">
				{prompt.useCount > 0 ? `Used ${prompt.useCount}×` : 'Not used yet'}
			</span>
		</div>
	</a>

	<button
		type="button"
		class="absolute top-2.5 right-2.5 z-10 rounded p-1 transition-colors hover:text-favorite focus-visible:ring-2 focus-visible:ring-primary/50 focus-visible:outline-none {prompt.isFavorited
			? 'text-favorite'
			: 'text-muted-foreground/40'}"
		aria-label={prompt.isFavorited ? 'Remove favorite' : 'Add favorite'}
		aria-pressed={prompt.isFavorited}
		data-testid="prompt-card-favorite"
		onclick={() => onToggleFavorite?.(prompt)}
	>
		<Star class="size-3.5 {prompt.isFavorited ? 'fill-favorite' : ''}" />
	</button>
</div>
