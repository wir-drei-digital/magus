<script lang="ts">
	import { BookMarked, Box, ScrollText, Sparkles, Star, Wrench } from '@lucide/svelte';
	import { itemIsFavorited, itemName, type LibraryItem } from '$lib/library/items';

	let {
		item,
		href,
		selected = false,
		compact = false,
		onToggleFavorite
	}: {
		item: LibraryItem;
		href: string;
		selected?: boolean;
		compact?: boolean;
		onToggleFavorite?: (item: LibraryItem) => void;
	} = $props();

	const favorited = $derived(itemIsFavorited(item));

	// Prompts double the first lines of their body as a preview; skills lean on
	// their description in the header instead.
	const preview = $derived(item.kind === 'prompt' ? item.prompt.content.trim() : '');
	const toolCount = $derived(item.kind === 'skill' ? (item.skill.requestedTools?.length ?? 0) : 0);
</script>

<!-- The card itself is the link (whole-surface navigation); the favorite button
     is a sibling overlaid in the corner so we avoid a button nested in an anchor. -->
<div class="group/card relative">
	<a
		{href}
		data-testid="library-card"
		data-kind={item.kind}
		data-selected={selected ? 'true' : undefined}
		class="flex h-full flex-col gap-2 rounded-xl border bg-card/50 p-3.5 transition-colors hover:border-primary/40 hover:bg-card focus-visible:border-primary/60 focus-visible:ring-2 focus-visible:ring-primary/50 focus-visible:outline-none {selected
			? 'border-primary/60 bg-card'
			: 'border-border'}"
	>
		<div class="flex items-start gap-2 pr-5">
			{#if item.kind === 'prompt'}
				{#if item.prompt.type === 'system'}
					<Sparkles class="mt-0.5 size-4 shrink-0 text-primary" />
				{:else}
					<ScrollText class="mt-0.5 size-4 shrink-0 text-muted-foreground" />
				{/if}
			{:else}
				<BookMarked class="mt-0.5 size-4 shrink-0 text-primary" />
			{/if}
			<div class="min-w-0 flex-1">
				<p class="truncate text-sm font-medium">{itemName(item)}</p>
				{#if item.kind === 'prompt'}
					{#if item.prompt.description && !compact}
						<p class="truncate text-xs text-muted-foreground">{item.prompt.description}</p>
					{/if}
				{:else if item.skill.description && !compact}
					<p class="line-clamp-2 text-xs text-muted-foreground">{item.skill.description}</p>
				{/if}
			</div>
		</div>

		{#if item.kind === 'prompt' && preview}
			<p
				class="font-mono text-xs leading-relaxed text-muted-foreground {compact
					? 'line-clamp-2'
					: 'line-clamp-3'}"
			>
				{preview}
			</p>
		{/if}

		<div class="mt-auto flex flex-wrap items-center gap-1.5 pt-0.5">
			<span
				class="rounded-full border border-input bg-secondary px-1.5 py-0.5 text-[9px] font-semibold tracking-wide text-muted-foreground uppercase"
			>
				{item.kind}
			</span>

			{#if item.kind === 'prompt'}
				{#each item.prompt.tags.slice(0, compact ? 1 : 2) as tag (tag.id)}
					<span
						class="rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-primary"
						>#{tag.name}</span
					>
				{/each}
				<span class="ml-auto shrink-0 text-[10px] text-muted-foreground">
					{item.prompt.useCount > 0 ? `Used ${item.prompt.useCount}×` : 'Not used yet'}
				</span>
			{:else}
				{#if item.skill.hasExecutableBundle}
					<span
						class="inline-flex items-center gap-1 rounded-full bg-amber-500/10 px-1.5 py-0.5 text-[10px] font-medium text-amber-600 dark:text-amber-400"
						title="Includes runnable code that executes in a sandbox"
					>
						<Box class="size-2.5" />
						sandbox
					</span>
				{/if}

				{#if toolCount > 0}
					<span
						class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-primary"
					>
						<Wrench class="size-2.5" />
						{toolCount}
						{toolCount === 1 ? 'tool' : 'tools'}
					</span>
				{/if}

				{#if item.skill.version && !compact}
					<span class="ml-auto shrink-0 text-[10px] text-muted-foreground">
						v{item.skill.version}
					</span>
				{/if}
			{/if}
		</div>
	</a>

	<button
		type="button"
		class="absolute top-2.5 right-2.5 z-10 rounded p-1 transition-colors hover:text-favorite focus-visible:ring-2 focus-visible:ring-primary/50 focus-visible:outline-none {favorited
			? 'text-favorite'
			: 'text-muted-foreground/40'}"
		aria-label={favorited ? 'Remove favorite' : 'Add favorite'}
		aria-pressed={favorited}
		data-testid="library-card-favorite"
		onclick={() => onToggleFavorite?.(item)}
	>
		<Star class="size-3.5 {favorited ? 'fill-favorite' : ''}" />
	</button>
</div>
