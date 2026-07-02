<script lang="ts">
	import { page } from '$app/state';
	import { base } from '$app/paths';
	import { LayoutGrid, Star, User, Users } from '@lucide/svelte';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';

	// The gallery (library/+layout.svelte) is the browse surface now; this rail is
	// a set of scope + tag filters that drive it via ?scope= / ?tag= in the URL.
	$effect(() => {
		void libraryNav.load(session.user?.currentWorkspaceId ?? null);
	});

	const scopes = $derived([
		{ key: null as string | null, label: 'All', icon: LayoutGrid, count: libraryNav.all.length },
		{ key: 'favorites', label: 'Favorites', icon: Star, count: libraryNav.favorites.length },
		// Shared/Personal only mean something inside a workspace.
		...(session.user?.currentWorkspaceId
			? [
					{ key: 'shared', label: 'Shared', icon: Users, count: libraryNav.shared.length },
					{ key: 'personal', label: 'Personal', icon: User, count: libraryNav.personal.length }
				]
			: [])
	]);

	// Tags stay prompt-only, computed from the merged list.
	const tags = $derived.by(() => {
		const counts = new Map<string, number>();
		for (const item of libraryNav.all) {
			if (item.kind !== 'prompt') continue;
			for (const tag of item.prompt.tags) counts.set(tag.name, (counts.get(tag.name) ?? 0) + 1);
		}
		return [...counts.entries()]
			.map(([name, count]) => ({ name, count }))
			.sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
	});

	const activeScope = $derived(page.url.searchParams.get('scope'));
	const activeTag = $derived(page.url.searchParams.get('tag'));
	const inLibrary = $derived(page.url.pathname.startsWith(`${base}/library`));

	const scopeHref = (key: string | null) =>
		key ? `${base}/library?scope=${key}` : `${base}/library`;
	const tagHref = (name: string) => `${base}/library?tag=${encodeURIComponent(name)}`;
</script>

<div data-testid="library-nav" class="contents">
	{#if libraryNav.loading && libraryNav.all.length === 0}
		<Sidebar.Group>
			<Sidebar.GroupContent>
				<Sidebar.Menu>
					{#each [1, 2, 3] as i (i)}
						<Sidebar.MenuItem>
							<Sidebar.MenuSkeleton />
						</Sidebar.MenuItem>
					{/each}
				</Sidebar.Menu>
			</Sidebar.GroupContent>
		</Sidebar.Group>
	{:else}
		<Sidebar.Group>
			<Sidebar.GroupLabel>Library</Sidebar.GroupLabel>
			<Sidebar.GroupContent>
				<Sidebar.Menu>
					{#each scopes as scope (scope.label)}
						{@const active = inLibrary && !activeTag && (activeScope ?? null) === scope.key}
						<Sidebar.MenuItem>
							<Sidebar.MenuButton
								isActive={active}
								data-testid="library-scope-{scope.key ?? 'all'}"
							>
								{#snippet child({ props })}
									<a {...props} href={scopeHref(scope.key)}>
										<scope.icon class="text-muted-foreground" />
										<span>{scope.label}</span>
									</a>
								{/snippet}
							</Sidebar.MenuButton>
							<Sidebar.MenuBadge class="text-[10px] text-muted-foreground">
								{scope.count}
							</Sidebar.MenuBadge>
						</Sidebar.MenuItem>
					{/each}
				</Sidebar.Menu>
			</Sidebar.GroupContent>
		</Sidebar.Group>

		{#if tags.length > 0}
			<Sidebar.Group data-testid="library-tags-nav">
				<Sidebar.GroupLabel>Tags</Sidebar.GroupLabel>
				<Sidebar.GroupContent>
					<Sidebar.Menu>
						{#each tags as tag (tag.name)}
							<Sidebar.MenuItem>
								<Sidebar.MenuButton
									isActive={inLibrary && activeTag === tag.name}
									data-testid="library-tag"
								>
									{#snippet child({ props })}
										<a {...props} href={tagHref(tag.name)}>
											<span
												class="w-4 shrink-0 text-center font-mono text-xs text-muted-foreground"
												aria-hidden="true">#</span
											>
											<span class="min-w-0 flex-1 truncate">{tag.name}</span>
										</a>
									{/snippet}
								</Sidebar.MenuButton>
								<Sidebar.MenuBadge class="text-[10px] text-muted-foreground">
									{tag.count}
								</Sidebar.MenuBadge>
							</Sidebar.MenuItem>
						{/each}
					</Sidebar.Menu>
				</Sidebar.GroupContent>
			</Sidebar.Group>
		{/if}
	{/if}
</div>
