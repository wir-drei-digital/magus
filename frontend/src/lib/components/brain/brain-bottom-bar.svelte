<script lang="ts">
	import { base } from '$app/paths';
	import { ChevronDown, ChevronUp, ExternalLink, FileText, History } from '@lucide/svelte';
	import {
		getBrainPageGuide,
		listBrainPageVersions,
		listPageSources,
		type BrainPageVersion,
		type PageBacklink,
		type PageGuide,
		type PageSourceEntry
	} from '$lib/ash/api';
	import { outlineFromDoc, type OutlineEntry } from '$lib/brain/outline';
	import { relativeTime } from '$lib/time';
	import TaskBoard from '$lib/components/plan/task-board.svelte';

	let {
		pageId,
		backlinks,
		getDoc,
		revision = 0,
		onViewVersion,
		showTasks = false
	}: {
		pageId: string;
		backlinks: PageBacklink[];
		/** Live editor document; the outline reflects unsaved edits too. */
		getDoc: () => unknown;
		/** Bumped on editor changes so an open outline stays current. */
		revision?: number;
		/** Opens the diff overlay for a version (classic view_version). */
		onViewVersion?: (versionId: string) => void;
		/**
		 * Content pages (kind === 'page') get a Tasks tab that hosts the task
		 * board. Tasks live on the page, so the board docks inside this bar
		 * instead of a second bottom bar. Templates and other kinds omit it.
		 */
		showTasks?: boolean;
	} = $props();

	type Tab = 'tasks' | 'outline' | 'sources' | 'related' | 'activity' | 'guide';
	// The document tabs keep their order; Tasks leads when present because it's
	// the interactive panel, so expanding the bar opens it first on a content page.
	const DOC_TABS: { id: Tab; label: string }[] = [
		{ id: 'outline', label: 'Outline' },
		{ id: 'sources', label: 'Sources' },
		{ id: 'related', label: 'Related' },
		{ id: 'activity', label: 'Activity' },
		{ id: 'guide', label: 'Guide' }
	];
	const tabs = $derived(
		showTasks ? [{ id: 'tasks' as Tab, label: 'Tasks' }, ...DOC_TABS] : DOC_TABS
	);

	// Classic parity: collapsed until a tab is clicked.
	let activeTab = $state<Tab | null>(null);

	let outline = $state<OutlineEntry[]>([]);
	let sources = $state<PageSourceEntry[] | null>(null);
	let versions = $state<BrainPageVersion[] | null>(null);
	let guide = $state<PageGuide | null>(null);

	// Debounce outline recompute: walking the full ProseMirror doc on every
	// keystroke (revision bump) lags large pages. ~150ms is imperceptible on open.
	let outlineTimer: ReturnType<typeof setTimeout> | null = null;
	$effect(() => {
		void revision;
		if (activeTab !== 'outline') return;
		if (outlineTimer) clearTimeout(outlineTimer);
		outlineTimer = setTimeout(() => (outline = outlineFromDoc(getDoc())), 150);
		return () => {
			if (outlineTimer) clearTimeout(outlineTimer);
		};
	});

	$effect(() => {
		void pageId;
		activeTab = null;
		sources = null;
		versions = null;
		guide = null;
	});

	function select(tab: Tab) {
		activeTab = activeTab === tab ? null : tab;
		if (activeTab === 'sources' && sources === null) {
			void listPageSources(pageId).then((result) => {
				if (result.success) sources = result.data;
			});
		}
		if (activeTab === 'activity' && versions === null) {
			void listBrainPageVersions(pageId).then((result) => {
				if (result.success) versions = result.data;
			});
		}
		if (activeTab === 'guide' && guide === null) {
			void getBrainPageGuide(pageId).then((result) => {
				if (result.success) guide = result.data;
			});
		}
	}

	/**
	 * Classic OutlineScroll: headings render in document order, so the nth
	 * outline entry maps to the nth heading element in the editor.
	 */
	function scrollToHeading(index: number) {
		const editor = document.querySelector('.ProseMirror');
		const heading = editor?.querySelectorAll('h1, h2, h3, h4, h5, h6')[index] as
			| HTMLElement
			| undefined;
		if (!heading) return;
		heading.scrollIntoView({ behavior: 'smooth', block: 'start' });
		heading.style.transition = 'background-color 1.1s ease';
		heading.style.backgroundColor = 'color-mix(in srgb, var(--primary) 18%, transparent)';
		setTimeout(() => {
			heading.style.backgroundColor = '';
			heading.style.transition = '';
		}, 1100);
	}
</script>

<div class="flex shrink-0 flex-col border-t" data-testid="brain-bottom-bar">
	<div class="flex items-center gap-1 px-3">
		{#each tabs as tab (tab.id)}
			<button
				type="button"
				class="border-b-2 px-2 py-1.5 text-xs transition-colors {activeTab === tab.id
					? 'border-primary font-medium text-primary'
					: 'border-transparent text-muted-foreground hover:text-foreground'}"
				data-testid="brain-tab-{tab.id}"
				aria-pressed={activeTab === tab.id}
				onclick={() => select(tab.id)}
			>
				{tab.label}
			</button>
		{/each}
		<span class="flex-1"></span>
		<button
			type="button"
			class="rounded p-1 text-muted-foreground hover:text-foreground"
			aria-label={activeTab ? 'Collapse panel' : 'Expand panel'}
			onclick={() => (activeTab = activeTab ? null : tabs[0].id)}
		>
			{#if activeTab}
				<ChevronDown class="size-3.5" />
			{:else}
				<ChevronUp class="size-3.5" />
			{/if}
		</button>
	</div>

	{#if activeTab === 'tasks'}
		<!-- The board manages its own header, summary, and internal scroll; cap
		     the dock height so a long list never pushes the editor off-screen. -->
		<div class="flex max-h-[min(50vh,420px)] min-h-0 flex-col" data-testid="brain-tasks">
			<TaskBoard brainPageId={pageId} />
		</div>
	{:else if activeTab}
		<div class="wb-scroll h-[180px] overflow-y-auto border-t px-3 py-2">
			{#if activeTab === 'outline'}
				{#if outline.length === 0}
					<p class="text-xs text-muted-foreground">No headings on this page.</p>
				{:else}
					<ul class="space-y-0.5" data-testid="brain-outline">
						{#each outline as heading, index (index)}
							<li style="padding-left: {(heading.depth - 1) * 0.75}rem">
								<button
									type="button"
									class="block w-full cursor-pointer truncate text-left text-xs text-secondary-foreground hover:text-primary"
									onclick={() => scrollToHeading(index)}
								>
									{heading.text}
								</button>
							</li>
						{/each}
					</ul>
				{/if}
			{:else if activeTab === 'sources'}
				{#if sources === null}
					<p class="text-xs text-muted-foreground">Loading…</p>
				{:else if sources.length === 0}
					<p class="text-xs text-muted-foreground">No sources referenced on this page.</p>
				{:else}
					<ul class="space-y-1">
						{#each sources as entry (entry.id)}
							<li>
								<a
									href={entry.source.url}
									target="_blank"
									rel="noopener noreferrer"
									class="flex items-center gap-1.5 text-xs text-secondary-foreground hover:text-foreground"
								>
									<ExternalLink class="size-3 shrink-0 text-muted-foreground" />
									<span class="truncate">{entry.source.title ?? entry.source.url}</span>
								</a>
							</li>
						{/each}
					</ul>
				{/if}
			{:else if activeTab === 'related'}
				{#if backlinks.length === 0}
					<p class="text-xs text-muted-foreground">No pages link here yet.</p>
				{:else}
					<ul class="space-y-1" data-testid="brain-related">
						{#each backlinks as link (link.id)}
							<li>
								<a
									href="{base}/brain/page/{link.sourcePage.id}"
									class="flex items-center gap-1.5 text-xs text-secondary-foreground hover:text-foreground"
								>
									{#if link.sourcePage.icon}
										<span class="shrink-0 leading-none">{link.sourcePage.icon}</span>
									{:else}
										<FileText class="size-3 shrink-0 text-muted-foreground" />
									{/if}
									<span class="truncate">{link.sourcePage.title ?? 'Untitled page'}</span>
								</a>
							</li>
						{/each}
					</ul>
				{/if}
			{:else if activeTab === 'guide'}
				{#if guide === null}
					<p class="text-xs text-muted-foreground">Loading…</p>
				{:else if !guide.constitution && guide.sectionGuides.length === 0 && !guide.pageType}
					<p class="text-xs text-muted-foreground">
						No guide yet. The agent writes one as this brain takes shape; you can also ask it to set
						instructions for the brain or this section.
					</p>
				{:else}
					<!-- Mirrors the agent's Brain Guide context block: constitution, then
					     inherited section guides (root to page, nearest last), then type. -->
					<div class="space-y-3" data-testid="brain-guide-panel">
						{#if guide.constitution}
							<section>
								<h4 class="mb-1 text-xs font-medium text-foreground">Brain constitution</h4>
								<p class="text-xs whitespace-pre-wrap text-secondary-foreground">
									{guide.constitution}
								</p>
							</section>
						{/if}
						{#each guide.sectionGuides as section (section.pageId)}
							<section>
								<h4 class="mb-1 text-xs font-medium text-foreground">
									{#if section.pageId === pageId}
										This page
									{:else}
										From <a href="{base}/brain/page/{section.pageId}" class="hover:text-primary"
											>{section.title}</a
										>
									{/if}
								</h4>
								<p class="text-xs whitespace-pre-wrap text-secondary-foreground">
									{section.instructions}
								</p>
							</section>
						{/each}
						{#if guide.pageType}
							<section class="flex items-center gap-1.5 text-xs text-muted-foreground">
								<span>Type:</span>
								<span class="rounded bg-secondary px-1.5 py-0.5 text-secondary-foreground">
									{guide.pageType}
								</span>
								{#if guide.typeTemplate}
									<a
										href="{base}/brain/page/{guide.typeTemplate.pageId}"
										class="hover:text-primary"
									>
										template: {guide.typeTemplate.title ?? 'Untitled'}
									</a>
								{/if}
							</section>
						{/if}
					</div>
				{/if}
			{:else if activeTab === 'activity'}
				{#if versions === null}
					<p class="text-xs text-muted-foreground">Loading…</p>
				{:else if versions.length === 0}
					<p class="text-xs text-muted-foreground">No edit history yet.</p>
				{:else}
					<ul class="space-y-0.5">
						{#each versions as version (version.version_id)}
							<li>
								<button
									type="button"
									class="flex w-full items-center gap-1.5 rounded px-1 py-0.5 text-left text-xs text-secondary-foreground transition-colors hover:bg-accent/40 disabled:pointer-events-none"
									data-testid="brain-version-row"
									disabled={!onViewVersion}
									onclick={() => onViewVersion?.(version.version_id)}
								>
									<History class="size-3 shrink-0 text-muted-foreground" />
									<span class="truncate">{version.preview ?? version.action_name ?? 'Edit'}</span>
									<span class="ml-auto shrink-0 text-muted-foreground">
										{relativeTime(version.inserted_at)}
									</span>
								</button>
							</li>
						{/each}
					</ul>
				{/if}
			{/if}
		</div>
	{/if}
</div>
