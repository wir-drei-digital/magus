<script lang="ts">
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { Plus, Search, SquareTerminal } from '@lucide/svelte';
	import {
		favoritePrompt,
		myPromptFavorites,
		unfavoritePrompt,
		type PromptSummary
	} from '$lib/ash/api';
	import { promptsNav } from '$lib/stores/prompts-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { Button } from '$lib/components/ui/button';
	import { EmptyState } from '$lib/components/ui/empty-state';
	import PromptFormDialog from '$lib/components/shell/prompt-form-dialog.svelte';
	import PromptCard from './prompt-card.svelte';

	let { selectedId = null, compact = false }: { selectedId?: string | null; compact?: boolean } =
		$props();

	const TYPES = [
		['all', 'All'],
		['system', 'System'],
		['user', 'User']
	] as const;

	let query = $state('');
	let typeFilter = $state<'all' | 'system' | 'user'>('all');
	let sort = $state<'used' | 'name'>('used');
	let createOpen = $state(false);

	$effect(() => {
		void promptsNav.load(session.user?.currentWorkspaceId ?? null);
	});

	// The rail sets these; the gallery reads them so the two stay in sync via the
	// URL (and they survive deep links + the back button).
	const scope = $derived(page.url.searchParams.get('scope'));
	const tag = $derived(page.url.searchParams.get('tag'));

	// All prompts = shared ∪ personal (favorites is a separate, overlapping list).
	const allPrompts = $derived<PromptSummary[]>([...promptsNav.shared, ...promptsNav.personal]);

	// The rail's scope/tag picks the base set; the toolbar narrows within it.
	const scoped = $derived.by(() => {
		if (tag) return allPrompts.filter((p) => p.tags.some((t) => t.name === tag));
		if (scope === 'favorites') return promptsNav.favorites;
		if (scope === 'shared') return promptsNav.shared;
		if (scope === 'personal') return promptsNav.personal;
		return allPrompts;
	});

	const shown = $derived.by(() => {
		const q = query.trim().toLowerCase();
		const filtered = scoped.filter((p) => {
			if (typeFilter !== 'all' && p.type !== typeFilter) return false;
			if (!q) return true;
			return (
				p.name.toLowerCase().includes(q) ||
				(p.description?.toLowerCase().includes(q) ?? false) ||
				p.content.toLowerCase().includes(q)
			);
		});
		return [...filtered].sort((a, b) =>
			sort === 'name' ? a.name.localeCompare(b.name) : b.useCount - a.useCount
		);
	});

	const heading = $derived(
		tag
			? `#${tag}`
			: scope === 'favorites'
				? 'Favorites'
				: scope === 'shared'
					? 'Shared'
					: scope === 'personal'
						? 'Personal'
						: 'All prompts'
	);

	const filtering = $derived(query.trim() !== '' || typeFilter !== 'all');
	const rawTotal = $derived(allPrompts.length);
	const cols = $derived(compact ? '160px' : '220px');

	// Keep the active scope/tag in the URL when opening a reader so the rail stays
	// highlighted and the narrowed gallery keeps showing the same subset.
	const cardHref = (id: string) => `${base}/prompts/${id}${page.url.search}`;

	async function toggleFavorite(p: PromptSummary) {
		if (p.isFavorited) {
			const favs = await myPromptFavorites();
			if (!favs.success) return;
			const fav = favs.data.find((entry) => entry.promptId === p.id);
			if (fav) await unfavoritePrompt(fav.id);
		} else {
			await favoritePrompt(p.id);
		}
		promptsNav.refresh();
	}
</script>

<div class="flex h-full min-h-0 flex-col" data-testid="prompt-gallery">
	<header class="flex shrink-0 items-center gap-2 border-b py-3 pr-4 pl-14 md:pl-4">
		<SquareTerminal class="size-4 shrink-0 text-muted-foreground" />
		<h1 class="flex-1 truncate text-base font-semibold">Prompts</h1>
		<Button size="sm" onclick={() => (createOpen = true)} data-testid="gallery-new-prompt">
			<Plus class="size-3.5" /> New prompt
		</Button>
	</header>

	<div class="flex shrink-0 flex-wrap items-center gap-2 border-b px-4 py-2">
		<label class="relative flex min-w-[9rem] flex-1 items-center">
			<Search class="pointer-events-none absolute left-2.5 size-3.5 text-muted-foreground" />
			<input
				bind:value={query}
				placeholder="Search prompts"
				data-testid="gallery-search"
				class="w-full rounded-md border border-input bg-secondary py-1.5 pr-2.5 pl-8 text-sm outline-none focus:border-primary/60"
			/>
		</label>

		<div class="flex shrink-0 items-center gap-0.5 rounded-md border border-input p-0.5 text-xs">
			{#each TYPES as [value, label] (value)}
				<button
					type="button"
					class="rounded px-2 py-1 transition-colors {typeFilter === value
						? 'bg-secondary font-medium text-foreground'
						: 'text-muted-foreground hover:text-foreground'}"
					onclick={() => (typeFilter = value)}
				>
					{label}
				</button>
			{/each}
		</div>

		<select
			bind:value={sort}
			aria-label="Sort prompts"
			class="shrink-0 rounded-md border border-input bg-secondary px-2 py-1.5 text-xs text-muted-foreground outline-none focus:border-primary/60"
		>
			<option value="used">Most used</option>
			<option value="name">A-Z</option>
		</select>
	</div>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
		<div class="p-4 {compact ? '' : 'mx-auto max-w-5xl md:p-6'}">
			{#if promptsNav.loading && rawTotal === 0}
				<div
					class="grid gap-3"
					style="grid-template-columns: repeat(auto-fill, minmax({cols}, 1fr));"
				>
					{#each [1, 2, 3, 4, 5, 6] as i (i)}
						<div class="h-28 animate-pulse rounded-xl border border-border bg-card/50"></div>
					{/each}
				</div>
			{:else if rawTotal === 0}
				<EmptyState
					class="h-auto py-16"
					data-testid="gallery-empty"
					title="No prompts yet"
					description="Save reusable prompts: instructions, personas, and starting points you want to reach for again."
				>
					{#snippet icon()}<SquareTerminal />{/snippet}
					<Button size="sm" onclick={() => (createOpen = true)}>
						<Plus class="size-3.5" /> New prompt
					</Button>
				</EmptyState>
			{:else}
				<div class="mb-3 flex items-baseline gap-2">
					<h2 class="text-xs font-medium text-muted-foreground">{heading}</h2>
					<span class="text-[11px] text-muted-foreground/70">{shown.length}</span>
				</div>

				{#if shown.length === 0}
					<p
						class="py-12 text-center text-sm text-muted-foreground"
						data-testid="gallery-scope-empty"
					>
						{#if filtering}
							No prompts match your search.
						{:else if scope === 'favorites'}
							No favorites yet. Tap the star on a prompt to keep it here.
						{:else if tag}
							No prompts tagged #{tag}.
						{:else if scope === 'shared'}
							Nothing shared to this workspace yet.
						{:else if scope === 'personal'}
							No personal prompts yet.
						{:else}
							No prompts here yet.
						{/if}
					</p>
				{:else}
					<div
						class="grid gap-3"
						style="grid-template-columns: repeat(auto-fill, minmax({cols}, 1fr));"
					>
						{#each shown as prompt (prompt.id)}
							<PromptCard
								{prompt}
								href={cardHref(prompt.id)}
								selected={prompt.id === selectedId}
								{compact}
								onToggleFavorite={toggleFavorite}
							/>
						{/each}
					</div>
				{/if}
			{/if}
		</div>
	</div>
</div>

<PromptFormDialog bind:open={createOpen} />
