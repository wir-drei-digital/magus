<script lang="ts">
	import { ChevronDown, ChevronUp, ExternalLink, FileText, NotebookPen } from '@lucide/svelte';
	import {
		getBrainPage,
		listBrainPageVersions,
		listPageBacklinks,
		listPageSources,
		type BrainPageDetail,
		type BrainPageVersion,
		type PageBacklink,
		type PageSourceEntry
	} from '$lib/ash/api';
	import { extractOutline, stripFrontmatter, type OutlineEntry } from '$lib/brain/outline';
	import { relativeTime } from '$lib/time';
	import Markdown from '$lib/components/chat/markdown.svelte';
	import PresenceAvatars from '$lib/components/chat/presence-avatars.svelte';
	import { ResourcePresence } from '$lib/chat/resource-presence.svelte';
	import { session } from '$lib/stores/session.svelte';
	import CompanionFrame from './companion-frame.svelte';

	let {
		pageId,
		revision = 0,
		onClose,
		onOpenPage
	}: {
		pageId: string;
		/** Bumped by the conversation store while the agent writes the page. */
		revision?: number;
		onClose: () => void;
		/** Related-tab click: swap the companion to another page. */
		onOpenPage: (pageId: string) => void;
	} = $props();

	const TABS = ['outline', 'sources', 'related', 'activity'] as const;
	type Tab = (typeof TABS)[number];

	// Live co-viewers on this page's shared presence topic (SPA + classic).
	const presence = new ResourcePresence();
	$effect(() => {
		void presence.start('page', pageId);
		return () => presence.stop();
	});

	let page = $state<BrainPageDetail | null>(null);
	let sources = $state<PageSourceEntry[]>([]);
	let backlinks = $state<PageBacklink[]>([]);
	let versions = $state<BrainPageVersion[]>([]);
	let loadError = $state<string | null>(null);

	let activeTab = $state<Tab>('outline');
	let panelOpen = $state(false);
	let body = $state<HTMLElement | null>(null);

	// Resizable outline/sources panel (classic 180px–50vh; SPA was fixed h-44).
	const PANEL_MIN = 180;
	function readPanelHeight(): number {
		if (typeof localStorage === 'undefined') return 220;
		const raw = Number(localStorage.getItem('magus:next:brain-panel-h'));
		return raw >= PANEL_MIN ? raw : 220;
	}
	let panelHeight = $state(readPanelHeight());

	function setPanelHeight(next: number) {
		const max = typeof window !== 'undefined' ? Math.round(window.innerHeight * 0.5) : 600;
		panelHeight = Math.max(PANEL_MIN, Math.min(max, next));
		try {
			localStorage.setItem('magus:next:brain-panel-h', String(panelHeight));
		} catch {
			// Best-effort persistence.
		}
	}

	function startResize(event: PointerEvent) {
		event.preventDefault();
		const startY = event.clientY;
		const startHeight = panelHeight;
		const onMove = (move: PointerEvent) => setPanelHeight(startHeight + (startY - move.clientY));
		const onUp = () => {
			window.removeEventListener('pointermove', onMove);
			window.removeEventListener('pointerup', onUp);
		};
		window.addEventListener('pointermove', onMove);
		window.addEventListener('pointerup', onUp);
	}

	// Last page id that finished loading. Plain field (not state): only the
	// effect below reads it, to tell "new page" from "refresh in place".
	let loadedId: string | null = null;

	const markdown = $derived(page?.body ? stripFrontmatter(page.body) : '');
	const outline = $derived<OutlineEntry[]>(markdown ? extractOutline(markdown) : []);

	// pageId is reactive (Related-tab clicks swap the companion in place);
	// revision bumps refetch WITHOUT blanking, so live agent writes update
	// the rendered page instead of flashing the skeleton.
	$effect(() => {
		const id = pageId;
		void revision;

		if (loadedId !== id) {
			page = null;
			loadError = null;
			panelOpen = false;
			activeTab = 'outline';
		}

		// Each callback drops stale responses: a fetch started before a page
		// swap must not land on the newer page's state.
		void getBrainPage(id).then((result) => {
			if (id !== pageId) return;
			if (result.success) {
				page = result.data;
				loadedId = id;
			} else {
				loadError = result.errors[0]?.message ?? 'Page could not be loaded';
			}
		});
		void listPageSources(id).then((result) => {
			if (id === pageId && result.success) sources = result.data;
		});
		void listPageBacklinks(id).then((result) => {
			if (id === pageId && result.success) backlinks = result.data;
		});
		void listBrainPageVersions(id).then((result) => {
			if (id === pageId && result.success) versions = result.data;
		});
	});

	function selectTab(tab: Tab) {
		if (panelOpen && activeTab === tab) {
			panelOpen = false;
			return;
		}
		activeTab = tab;
		panelOpen = true;
	}

	function scrollToHeading(entry: OutlineEntry) {
		const headings = body?.querySelectorAll('h1, h2, h3, h4, h5, h6');
		headings?.[entry.index]?.scrollIntoView({ behavior: 'smooth', block: 'start' });
	}
</script>

<CompanionFrame
	title={page?.title ?? 'Untitled page'}
	meta={page ? `Updated ${relativeTime(page.updatedAt)}` : null}
	pill={page ? (page.brain.workspaceId ? 'Workspace' : 'Personal') : null}
	{onClose}
>
	{#snippet icon()}
		{#if page?.icon}
			<span class="shrink-0 text-base leading-none">{page.icon}</span>
		{:else}
			<NotebookPen class="size-4 shrink-0 text-muted-foreground" />
		{/if}
	{/snippet}

	{#snippet headerActions()}
		<PresenceAvatars viewers={presence.viewers} selfUserId={session.user?.id} max={3} />
	{/snippet}

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto px-5 py-4" bind:this={body}>
		{#if loadError}
			<p class="text-sm text-destructive">{loadError}</p>
		{:else if !page}
			<div class="space-y-3">
				<div class="h-5 w-1/2 animate-pulse rounded bg-muted"></div>
				<div class="h-4 w-full animate-pulse rounded bg-muted"></div>
				<div class="h-4 w-2/3 animate-pulse rounded bg-muted"></div>
			</div>
		{:else if markdown}
			<Markdown text={markdown} />
		{:else}
			<p class="text-sm text-muted-foreground">This page is empty.</p>
		{/if}
	</div>

	{#snippet footer()}
		{#if panelOpen}
			<div
				class="flex shrink-0 flex-col border-t"
				style="height: {panelHeight}px"
				data-testid="companion-panel"
			>
				<!-- Drag (or arrow-key) the top edge to resize the panel. -->
				<button
					type="button"
					class="h-1.5 w-full shrink-0 cursor-row-resize transition-colors hover:bg-primary/20"
					aria-label="Resize panel"
					data-testid="companion-panel-resize"
					onpointerdown={startResize}
					onkeydown={(event) => {
						if (event.key === 'ArrowUp') {
							event.preventDefault();
							setPanelHeight(panelHeight + 24);
						} else if (event.key === 'ArrowDown') {
							event.preventDefault();
							setPanelHeight(panelHeight - 24);
						}
					}}
				></button>
				<div class="wb-scroll flex-1 overflow-y-auto px-4 py-3">
					{#if activeTab === 'outline'}
						{#if outline.length === 0}
							<p class="text-xs text-muted-foreground">No headings on this page.</p>
						{:else}
							<ul class="space-y-1">
								{#each outline as entry (entry.index)}
									<li style="padding-left: {(entry.depth - 1) * 12}px">
										<button
											type="button"
											class="text-left text-xs text-secondary-foreground transition-colors hover:text-foreground"
											onclick={() => scrollToHeading(entry)}
										>
											{entry.text}
										</button>
									</li>
								{/each}
							</ul>
						{/if}
					{:else if activeTab === 'sources'}
						{#if sources.length === 0}
							<p class="text-xs text-muted-foreground">No sources referenced.</p>
						{:else}
							<ul class="space-y-1.5">
								{#each sources as entry (entry.id)}
									<li>
										<a
											href={entry.source.url}
											target="_blank"
											rel="noopener noreferrer"
											class="group flex items-center gap-1.5 text-xs text-secondary-foreground transition-colors hover:text-foreground"
										>
											<ExternalLink class="size-3 shrink-0 text-muted-foreground" />
											<span class="min-w-0 truncate">
												{entry.source.title ?? entry.source.url}
											</span>
											{#if entry.source.ingestStatus !== 'ingested'}
												<span class="shrink-0 text-[10px] text-muted-foreground">
													({entry.source.ingestStatus})
												</span>
											{/if}
										</a>
									</li>
								{/each}
							</ul>
						{/if}
					{:else if activeTab === 'related'}
						{#if backlinks.length === 0}
							<p class="text-xs text-muted-foreground">No pages link here yet.</p>
						{:else}
							<ul class="space-y-1.5">
								{#each backlinks as link (link.id)}
									<li>
										<button
											type="button"
											class="flex items-center gap-1.5 text-left text-xs text-secondary-foreground transition-colors hover:text-foreground"
											onclick={() => onOpenPage(link.sourcePage.id)}
										>
											{#if link.sourcePage.icon}
												<span class="shrink-0 leading-none">{link.sourcePage.icon}</span>
											{:else}
												<FileText class="size-3 shrink-0 text-muted-foreground" />
											{/if}
											<span class="min-w-0 truncate">
												{link.sourcePage.title ?? 'Untitled page'}
											</span>
											{#if page?.title && link.targetTitleAtLinkTime !== page.title}
												<!-- Rename drift: the [[link]] text predates this page's rename. -->
												<span
													class="shrink-0 text-[10px] text-muted-foreground"
													title={`Links to this page as "${link.targetTitleAtLinkTime}"`}
												>
													↻
												</span>
											{/if}
										</button>
									</li>
								{/each}
							</ul>
						{/if}
					{:else if versions.length === 0}
						<p class="text-xs text-muted-foreground">No version history yet.</p>
					{:else}
						<ul class="space-y-2">
							{#each versions as version (version.version_id)}
								<li class="text-xs">
									<p class="text-secondary-foreground">
										{relativeTime(version.inserted_at)}
										{#if version.action_name}
											<span class="text-muted-foreground"> · {version.action_name}</span>
										{/if}
									</p>
									{#if version.preview}
										<p class="truncate text-muted-foreground">{version.preview}</p>
									{/if}
								</li>
							{/each}
						</ul>
					{/if}
				</div>
			</div>
		{/if}

		<div class="flex shrink-0 items-center border-t px-2" data-testid="companion-tabs">
			{#each TABS as tab (tab)}
				<button
					type="button"
					class="border-b-2 px-3 py-2 text-xs capitalize transition-colors {panelOpen &&
					activeTab === tab
						? 'border-primary font-medium text-foreground'
						: 'border-transparent text-muted-foreground hover:text-foreground'}"
					data-testid="companion-tab-{tab}"
					onclick={() => selectTab(tab)}
				>
					{tab}
				</button>
			{/each}
			<span class="flex-1"></span>
			<button
				type="button"
				class="rounded-md p-1 text-muted-foreground transition-colors hover:text-foreground"
				aria-label={panelOpen ? 'Collapse panel' : 'Expand panel'}
				onclick={() => (panelOpen = !panelOpen)}
			>
				{#if panelOpen}
					<ChevronDown class="size-3.5" />
				{:else}
					<ChevronUp class="size-3.5" />
				{/if}
			</button>
		</div>
	{/snippet}
</CompanionFrame>
