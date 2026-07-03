<script lang="ts">
	import { ChevronDown, ChevronUp, ExternalLink, FileText, NotebookPen } from '@lucide/svelte';
	import {
		brainPages,
		getBrainPageForEdit,
		listBrainPageVersions,
		listPageBacklinks,
		listPageSources,
		saveBrainPageProsemirror,
		type BrainPageEditable,
		type BrainPageVersion,
		type PageBacklink,
		type PageSourceEntry,
		type PageTreeNode
	} from '$lib/ash/api';
	import { extractOutline, stripFrontmatter, type OutlineEntry } from '$lib/brain/outline';
	import {
		clearBrainFileMap,
		extractBrainFileIds,
		populateBrainFileMap
	} from '$lib/brain/file-map';
	import { bubbleSelectionText } from '$lib/chat/bubble-action';
	import { relativeTime } from '$lib/time';
	import BrainEditor from '$lib/components/brain/brain-editor.svelte';
	import PresenceAvatars from '$lib/components/chat/presence-avatars.svelte';
	import { ResourcePresence } from '$lib/chat/resource-presence.svelte';
	import { session } from '$lib/stores/session.svelte';
	import CompanionFrame from './companion-frame.svelte';

	let {
		pageId,
		revision = 0,
		onClose,
		onOpenPage,
		onAsk,
		onAskSelection
	}: {
		pageId: string;
		/** Bumped by the conversation store while the agent writes the page. */
		revision?: number;
		onClose: () => void;
		/** Related-tab click: swap the companion to another page. */
		onOpenPage: (pageId: string) => void;
		/** Editor bubble Refine: drop the instruction text into the composer. */
		onAsk?: (text: string) => void;
		/** Editor bubble Ask: pin the selection as a composer context pill. */
		onAskSelection?: (selection: { text: string; title: string | null }) => void;
	} = $props();

	const TABS = ['outline', 'sources', 'related', 'activity'] as const;
	type Tab = (typeof TABS)[number];

	// Live co-viewers on this page's shared presence topic (SPA + classic).
	const presence = new ResourcePresence();
	$effect(() => {
		void presence.start('page', pageId);
		return () => presence.stop();
	});

	let page = $state<BrainPageEditable | null>(null);
	let sources = $state<PageSourceEntry[]>([]);
	let backlinks = $state<PageBacklink[]>([]);
	let versions = $state<BrainPageVersion[]>([]);
	let siblingPages = $state<PageTreeNode[]>([]);
	let loadError = $state<string | null>(null);

	let editorRef = $state<BrainEditor | null>(null);
	let lockVersion = 0;
	let dirty = $state(false);
	let saveState = $state<'idle' | 'saving' | 'saved' | 'error'>('idle');
	let saveError = $state<string | null>(null);
	let conflictNotice = $state<string | null>(null);
	let saveTimer: ReturnType<typeof setTimeout> | null = null;

	let activeTab = $state<Tab>('outline');
	let panelOpen = $state(false);
	let body = $state<HTMLElement | null>(null);

	function scheduleSave() {
		dirty = true;
		if (saveTimer) clearTimeout(saveTimer);
		saveTimer = setTimeout(() => void save(), 1000);
	}

	async function save(retrying = false) {
		const doc = editorRef?.getJSON();
		if (!page || !doc) return;
		saveState = 'saving';
		saveError = null;
		const id = page.id;

		const result = await saveBrainPageProsemirror(id, doc, lockVersion);
		if (id !== pageId) return;

		if (result.status === 'saved') {
			lockVersion = result.lockVersion;
			dirty = false;
			saveState = 'saved';
			return;
		}
		if (result.status === 'conflict' && !retrying) {
			// LWW recovery (classic parity): adopt the server version, resave on top.
			const refreshed = await getBrainPageForEdit(id);
			if (id !== pageId) return;
			lockVersion = result.currentVersion ?? (refreshed.success ? refreshed.data.lockVersion : 0);
			conflictNotice = 'This page changed elsewhere. Your version was saved over it.';
			await save(true);
			return;
		}
		saveState = 'error';
		saveError = result.message;
	}

	function onBubbleAction(event: string, payload: Record<string, unknown>) {
		const text = bubbleSelectionText(event, payload);
		if (!text) return;
		if (event === 'ask' && onAskSelection) {
			onAskSelection({ text, title: page?.title ?? null });
		} else {
			onAsk?.(text);
		}
	}

	function openPageByTitle(title: string) {
		const hit = siblingPages.find(
			(node) => (node.title ?? '').toLowerCase() === title.toLowerCase()
		);
		if (hit) onOpenPage(hit.id);
	}

	// Resolve file/image blocks so their NodeViews render the real file rather
	// than the "no longer available" placeholder (classic parity).
	async function refreshFileBlocks(id: string, bodyMd: string | null | undefined) {
		const hasFiles = extractBrainFileIds(bodyMd).length > 0;
		await populateBrainFileMap(id, bodyMd);
		if (hasFiles && id === pageId && !dirty) editorRef?.setContent(page?.prosemirror ?? {});
	}

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

	const markdown = $derived(page?.body ? stripFrontmatter(page.body) : '');
	const outline = $derived<OutlineEntry[]>(markdown ? extractOutline(markdown) : []);

	// Initial load + page swap (Related-tab clicks reuse this companion). The
	// editor is keyed by page id, so it remounts with fresh content on swap.
	$effect(() => {
		const id = pageId;
		page = null;
		loadError = null;
		panelOpen = false;
		activeTab = 'outline';
		dirty = false;
		saveState = 'idle';
		conflictNotice = null;

		void getBrainPageForEdit(id).then((result) => {
			if (id !== pageId) return;
			if (result.success) {
				page = result.data;
				lockVersion = result.data.lockVersion;
				void refreshFileBlocks(id, result.data.body);
				void brainPages(result.data.brain.id).then((pagesResult) => {
					if (id === pageId && pagesResult.success) siblingPages = pagesResult.data;
				});
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

		return () => {
			if (saveTimer) clearTimeout(saveTimer);
			clearBrainFileMap(id);
		};
	});

	// Live agent writes bump `revision`: refetch in place (no skeleton flash).
	// When the user is mid-edit, note the overwrite instead of clobbering them.
	let revisionArmed = false;
	$effect(() => {
		void revision;
		if (!revisionArmed) {
			revisionArmed = true;
			return;
		}
		const id = pageId;
		void getBrainPageForEdit(id).then((result) => {
			if (id !== pageId || !result.success || !page) return;
			if (dirty) {
				conflictNotice =
					'Someone else is editing this page. Your next save will overwrite their changes.';
				return;
			}
			page = result.data;
			lockVersion = result.data.lockVersion;
			editorRef?.setContent(result.data.prosemirror);
			void refreshFileBlocks(id, result.data.body);
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

	{#if conflictNotice}
		<p class="border-b bg-warning/10 px-4 py-1.5 text-xs text-warning" data-testid="page-conflict">
			{conflictNotice}
		</p>
	{/if}
	{#if saveError}
		<p class="border-b bg-destructive/10 px-4 py-1.5 text-xs text-destructive">{saveError}</p>
	{/if}

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto px-4 py-4" bind:this={body}>
		{#if loadError}
			<p class="text-sm text-destructive">{loadError}</p>
		{:else if !page}
			<div class="space-y-3">
				<div class="h-5 w-1/2 animate-pulse rounded bg-muted"></div>
				<div class="h-4 w-full animate-pulse rounded bg-muted"></div>
				<div class="h-4 w-2/3 animate-pulse rounded bg-muted"></div>
			</div>
		{:else}
			{#key page.id}
				<BrainEditor
					bind:this={editorRef}
					content={page.prosemirror}
					pages={siblingPages}
					pageId={page.id}
					workspaceId={page.brain.workspaceId}
					onChange={scheduleSave}
					onPageRefClick={openPageByTitle}
					{onBubbleAction}
				/>
			{/key}
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
			<span class="px-2 text-[11px] text-muted-foreground" data-testid="page-save-state">
				{#if saveState === 'saving'}
					Saving…
				{:else if dirty}
					Unsaved
				{:else if saveState === 'saved'}
					Saved
				{/if}
			</span>
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
