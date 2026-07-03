<script lang="ts">
	import { untrack } from 'svelte';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import {
		BookMarked,
		FileText,
		Files,
		MessageSquare,
		ScrollText,
		Search as SearchIcon,
		SearchX
	} from '@lucide/svelte';
	import { EmptyState } from '$lib/components/ui/empty-state';
	import { searchAll, type SearchResult, type SearchResultType } from '$lib/ash/api';

	type Tab = 'all' | SearchResultType;

	const TABS: { id: Tab; label: string }[] = [
		{ id: 'all', label: 'All' },
		{ id: 'conversation', label: 'Conversations' },
		{ id: 'message', label: 'Messages' },
		{ id: 'prompt', label: 'Prompts' },
		{ id: 'skill', label: 'Skills' },
		{ id: 'resource', label: 'Files' },
		{ id: 'chunk', label: 'File content' }
	];

	const TYPE_META: Record<SearchResultType, { label: string; icon: typeof MessageSquare }> = {
		message: { label: 'Message', icon: MessageSquare },
		conversation: { label: 'Conversation', icon: MessageSquare },
		prompt: { label: 'Prompt', icon: ScrollText },
		skill: { label: 'Skill', icon: BookMarked },
		resource: { label: 'File', icon: Files },
		chunk: { label: 'File content', icon: FileText }
	};

	let query = $state(page.url.searchParams.get('q') ?? '');
	let activeTab = $state<Tab>('all');
	let results = $state<SearchResult[]>([]);
	let loading = $state(false);
	let searched = $state(false);

	let reqId = 0;
	let debounce: ReturnType<typeof setTimeout> | null = null;

	// Seed from the URL (?q= set by the Cmd+K overlay or a shared link) and
	// re-run when it changes externally. untrack so typing — which mutates
	// `query`/`activeTab` — doesn't re-trigger this seeding effect.
	$effect(() => {
		const q = page.url.searchParams.get('q') ?? '';
		untrack(() => {
			query = q;
			void runSearch(q, activeTab);
		});
	});

	async function runSearch(q: string, tab: Tab) {
		const trimmed = q.trim();
		if (trimmed.length < 2) {
			results = [];
			searched = false;
			loading = false;
			return;
		}
		const myReq = ++reqId;
		loading = true;
		searched = true;
		const result = await searchAll(trimmed, tab === 'all' ? undefined : tab);
		if (myReq !== reqId) return;
		if (result.success) results = result.data;
		loading = false;
	}

	function onInput() {
		if (debounce) clearTimeout(debounce);
		debounce = setTimeout(() => void runSearch(query, activeTab), 200);
	}

	function selectTab(tab: Tab) {
		activeTab = tab;
		void runSearch(query, tab);
	}

	function resultUrl(result: SearchResult): string {
		switch (result.type) {
			case 'message':
				return `${base}/chat/${result.metadata.conversation_id}?highlight=${result.id}`;
			case 'conversation':
				return `${base}/chat/${result.id}`;
			case 'prompt':
				return `${base}/library/prompts/${result.id}`;
			case 'skill':
				return `${base}/library/skills/${result.id}`;
			case 'resource':
				return `${base}/files/file/${result.id}`;
			case 'chunk':
				return `${base}/files/file/${result.metadata.file_id}`;
		}
	}
</script>

<svelte:head>
	<title>Magus — Search</title>
</svelte:head>

<div class="flex h-full min-h-0 flex-col" data-testid="search-view">
	<header
		class="flex min-h-11 shrink-0 items-center gap-2 border-b bg-background/80 py-2 pr-6 pl-14 md:pl-6"
	>
		<SearchIcon class="size-4 shrink-0 text-muted-foreground" />
		<h1 class="min-w-0 flex-1 truncate text-base font-semibold">Search</h1>
	</header>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
		<div class="mx-auto w-full max-w-3xl p-6">
			<div class="relative mb-3">
				<SearchIcon
					class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground"
				/>
				<!-- svelte-ignore a11y_autofocus — dedicated search surface -->
				<input
					type="text"
					bind:value={query}
					oninput={onInput}
					autofocus
					placeholder="Search messages, conversations, prompts, skills, files…"
					data-testid="search-input"
					class="w-full rounded-lg border border-input bg-secondary py-2 pr-3 pl-9 text-sm outline-none placeholder:text-muted-foreground focus:border-primary/60"
				/>
			</div>

			<div class="mb-4 flex flex-wrap items-center gap-1.5" data-testid="search-tabs">
				{#each TABS as tab (tab.id)}
					<button
						type="button"
						class="wb-pill-btn shrink-0 {activeTab === tab.id ? 'wb-pill-btn-active' : ''}"
						data-testid="search-tab-{tab.id}"
						onclick={() => selectTab(tab.id)}
					>
						{tab.label}
					</button>
				{/each}
			</div>

			{#if loading && results.length === 0}
				<!-- Quiet load. -->
			{:else if !searched}
				<EmptyState
					class="h-auto py-16"
					title="Search your workspace"
					description="Find across messages, conversations, prompts, skills, and files. Type at least two characters to begin."
				>
					{#snippet icon()}<SearchIcon />{/snippet}
				</EmptyState>
			{:else if results.length === 0}
				<EmptyState
					class="h-auto py-16"
					data-testid="search-empty"
					title="No matches"
					description="Nothing matched your search. Try different keywords or another filter."
				>
					{#snippet icon()}<SearchX />{/snippet}
				</EmptyState>
			{:else}
				<ul class="flex flex-col gap-1" data-testid="search-results">
					{#each results as result (`${result.type}:${result.id}`)}
						{@const meta = TYPE_META[result.type]}
						<li>
							<a
								href={resultUrl(result)}
								class="flex items-start gap-3 rounded-lg px-3 py-2.5 transition-colors hover:bg-accent/60"
								data-testid="search-result"
							>
								<meta.icon class="mt-0.5 size-4 shrink-0 text-muted-foreground" />
								<span class="min-w-0 flex-1">
									<span class="flex items-center gap-2">
										<span class="truncate text-sm font-medium">{result.title}</span>
										<span
											class="shrink-0 rounded-full bg-secondary px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground"
										>
											{meta.label}
										</span>
									</span>
									<!-- Snippet is server-escaped; only <mark> highlight tags are injected. -->
									<span class="search-snippet block truncate text-xs text-muted-foreground">
										{@html result.snippet}
									</span>
								</span>
							</a>
						</li>
					{/each}
				</ul>
			{/if}
		</div>
	</div>
</div>

<style>
	/* Highlight marks from the server-rendered snippet. */
	.search-snippet :global(mark) {
		background-color: var(--color-primary);
		color: var(--color-primary-foreground);
		border-radius: 2px;
		padding: 0 1px;
	}
</style>
