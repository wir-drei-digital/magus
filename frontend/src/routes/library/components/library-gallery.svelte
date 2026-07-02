<script lang="ts">
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { Download, LibraryBig, Plus, Search } from '@lucide/svelte';
	import {
		favoritePrompt,
		favoriteSkill,
		myPromptFavorites,
		mySkillFavorites,
		unfavoritePrompt,
		unfavoriteSkill
	} from '$lib/ash/api';
	import {
		itemIsFavorited,
		itemMatches,
		itemName,
		itemUseCount,
		type LibraryItem
	} from '$lib/library/items';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { Button } from '$lib/components/ui/button';
	import { EmptyState } from '$lib/components/ui/empty-state';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import LibraryCard from './library-card.svelte';

	let { selectedId = null, compact = false }: { selectedId?: string | null; compact?: boolean } =
		$props();

	const TYPES = [
		['all', 'All'],
		['prompts', 'Prompts'],
		['skills', 'Skills']
	] as const;

	// ?type= comes from the legacy /prompts and /skills redirects; read once.
	const urlType = page.url.searchParams.get('type');
	let typeFilter = $state<'all' | 'prompts' | 'skills'>(
		urlType === 'prompts' || urlType === 'skills' ? urlType : 'all'
	);
	let query = $state('');
	let sort = $state<'used' | 'name'>('used');

	$effect(() => {
		void libraryNav.load(session.user?.currentWorkspaceId ?? null);
	});

	const scope = $derived(page.url.searchParams.get('scope'));
	const tag = $derived(page.url.searchParams.get('tag'));

	// The rail's scope/tag picks the base set; the toolbar narrows within it.
	// A tag filter implies prompts (skills have no tags — see the spec).
	const scoped = $derived.by(() => {
		if (tag) {
			return libraryNav.all.filter(
				(item) => item.kind === 'prompt' && item.prompt.tags.some((t) => t.name === tag)
			);
		}
		if (scope === 'favorites') return libraryNav.favorites;
		if (scope === 'shared') return libraryNav.shared;
		if (scope === 'personal') return libraryNav.personal;
		return libraryNav.all;
	});

	const shown = $derived.by(() => {
		const filtered = scoped.filter((item) => {
			if (typeFilter === 'prompts' && item.kind !== 'prompt') return false;
			if (typeFilter === 'skills' && item.kind !== 'skill') return false;
			return itemMatches(item, query);
		});
		return [...filtered].sort((a, b) =>
			sort === 'name'
				? itemName(a).localeCompare(itemName(b))
				: itemUseCount(b) - itemUseCount(a)
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
						: 'All'
	);

	const filtering = $derived(query.trim() !== '' || typeFilter !== 'all');
	const rawTotal = $derived(libraryNav.all.length);
	const cols = $derived(compact ? '160px' : '220px');

	const cardHref = (item: LibraryItem) =>
		`${base}/library/${item.kind === 'prompt' ? 'prompts' : 'skills'}/${item.id}${page.url.search}`;

	async function toggleFavorite(item: LibraryItem) {
		if (item.kind === 'prompt') {
			if (item.prompt.isFavorited) {
				const favs = await myPromptFavorites();
				if (!favs.success) return;
				const fav = favs.data.find((entry) => entry.promptId === item.id);
				if (fav) await unfavoritePrompt(fav.id);
			} else {
				await favoritePrompt(item.id);
			}
		} else {
			if (itemIsFavorited(item)) {
				const favs = await mySkillFavorites();
				if (!favs.success) return;
				const fav = favs.data.find((entry) => entry.skillId === item.id);
				if (fav) await unfavoriteSkill(fav.id);
			} else {
				await favoriteSkill(item.id);
			}
		}
		libraryNav.refresh();
	}
</script>

<div class="flex h-full min-h-0 flex-col" data-testid="library-gallery">
	<header class="flex shrink-0 items-center gap-2 border-b py-3 pr-4 pl-14 md:pl-4">
		<LibraryBig class="size-4 shrink-0 text-muted-foreground" />
		<h1 class="flex-1 truncate text-base font-semibold">Library</h1>
		<DropdownMenu.Root>
			<DropdownMenu.Trigger data-testid="gallery-new">
				{#snippet child({ props })}
					<Button {...props} size="sm"><Plus class="size-3.5" /> New</Button>
				{/snippet}
			</DropdownMenu.Trigger>
			<DropdownMenu.Content align="end">
				<DropdownMenu.Item
					data-testid="gallery-new-prompt"
					onSelect={() => (libraryNav.createPromptOpen = true)}
				>
					New prompt
				</DropdownMenu.Item>
				<DropdownMenu.Item
					data-testid="gallery-new-skill"
					onSelect={() => (libraryNav.createSkillOpen = true)}
				>
					New skill
				</DropdownMenu.Item>
				<DropdownMenu.Separator />
				<DropdownMenu.Item
					data-testid="gallery-import-skill"
					onSelect={() => (libraryNav.importOpen = true)}
				>
					<Download class="size-3.5" /> Import skill
				</DropdownMenu.Item>
			</DropdownMenu.Content>
		</DropdownMenu.Root>
	</header>

	<div class="flex shrink-0 flex-wrap items-center gap-2 border-b px-4 py-2">
		<label class="relative flex min-w-[9rem] flex-1 items-center">
			<Search class="pointer-events-none absolute left-2.5 size-3.5 text-muted-foreground" />
			<input
				bind:value={query}
				placeholder="Search library"
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
			aria-label="Sort library"
			class="shrink-0 rounded-md border border-input bg-secondary px-2 py-1.5 text-xs text-muted-foreground outline-none focus:border-primary/60"
		>
			<option value="used">Most used</option>
			<option value="name">A-Z</option>
		</select>
	</div>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
		<div class="p-4 {compact ? '' : 'mx-auto max-w-5xl md:p-6'}">
			{#if libraryNav.loading && rawTotal === 0}
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
					title="Your library is empty"
					description="Save reusable prompts and skills: instructions, personas, and runnable tools you want to reach for again."
				>
					{#snippet icon()}<LibraryBig />{/snippet}
					<div class="flex flex-wrap items-center justify-center gap-2">
						<Button size="sm" onclick={() => (libraryNav.createPromptOpen = true)}>
							<Plus class="size-3.5" /> New prompt
						</Button>
						<Button
							size="sm"
							variant="outline"
							onclick={() => (libraryNav.createSkillOpen = true)}
						>
							<Plus class="size-3.5" /> New skill
						</Button>
						<Button size="sm" variant="outline" onclick={() => (libraryNav.importOpen = true)}>
							<Download class="size-3.5" /> Import skill
						</Button>
					</div>
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
							No items match your search.
						{:else if scope === 'favorites'}
							No favorites yet. Tap the star on an item to keep it here.
						{:else if tag}
							Nothing tagged #{tag}.
						{:else if scope === 'shared'}
							Nothing shared to this workspace yet.
						{:else if scope === 'personal'}
							Nothing personal yet.
						{:else}
							Nothing here yet.
						{/if}
					</p>
				{:else}
					<div
						class="grid gap-3"
						style="grid-template-columns: repeat(auto-fill, minmax({cols}, 1fr));"
					>
						{#each shown as item (item.kind + ':' + item.id)}
							<LibraryCard
								{item}
								href={cardHref(item)}
								selected={item.id === selectedId}
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
