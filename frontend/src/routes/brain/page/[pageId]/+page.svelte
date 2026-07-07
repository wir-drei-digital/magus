<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { MessageSquare, NotebookPen, Paperclip, Trash2 } from '@lucide/svelte';
	import MobileNavButton from '$lib/components/shell/mobile-nav-button.svelte';
	import {
		brainPages,
		getBrainPageForEdit,
		listPageBacklinks,
		renameBrainPage,
		saveBrainPageProsemirror,
		trashBrainPage,
		type BrainPageEditable,
		type PageBacklink,
		type PageTreeNode
	} from '$lib/ash/api';
	import {
		brainPageVersionBody,
		brainPageVersionDiff,
		openCompanionChat,
		updateBrainPageBody,
		type PageVersionDiff
	} from '$lib/ash/api';
	import { joinBrainUpdates } from '$lib/realtime/brain-updates';
	import {
		clearBrainFileMap,
		extractBrainFileIds,
		populateBrainFileMap
	} from '$lib/brain/file-map';
	import { relativeTime } from '$lib/time';
	import BrainBottomBar from '$lib/components/brain/brain-bottom-bar.svelte';
	import TaskBottomBar from '$lib/components/brain/task-bottom-bar.svelte';
	import VersionDiffOverlay from '$lib/components/brain/version-diff-overlay.svelte';
	import PresenceAvatars from '$lib/components/chat/presence-avatars.svelte';
	import { ResourcePresence } from '$lib/chat/resource-presence.svelte';
	// Lazy: keeps the chat view stack out of the brain route chunk.
	const loadConversationCompanion = () =>
		import('$lib/components/companions/conversation-companion.svelte');
	import * as Resizable from '$lib/components/ui/resizable';
	import BrainEditor from '$lib/components/brain/brain-editor.svelte';
	import BrainFilePickerDialog from '$lib/components/brain/brain-file-picker-dialog.svelte';
	import { brainNav } from '$lib/stores/brain-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';

	const pageId = $derived(page.params.pageId!);

	// Live co-viewers on this page's shared presence topic (classic brain page
	// view tracks the same `presence:page:<id>` topic, so SPA + classic + the
	// side-pane companion all appear together).
	const presence = new ResourcePresence();
	$effect(() => {
		void presence.start('page', pageId);
		return () => presence.stop();
	});

	// Title/icon from the nav tree while the page detail loads — the header
	// renders immediately with the right text instead of appearing later.
	const navNode = $derived.by(() => {
		for (const nodes of [...Object.values(brainNav.roots), ...Object.values(brainNav.children)]) {
			const hit = nodes.find((node) => node.id === pageId);
			if (hit) return hit;
		}
		return null;
	});

	let pageData = $state<BrainPageEditable | null>(null);
	let siblingPages = $state<PageTreeNode[]>([]);
	let backlinks = $state<PageBacklink[]>([]);
	let loadError = $state<string | null>(null);

	let editorRef = $state<BrainEditor | null>(null);
	let filePickerOpen = $state(false);
	let lockVersion = $state(0);
	let dirty = $state(false);
	let saveState = $state<'idle' | 'saving' | 'saved' | 'error'>('idle');
	let saveError = $state<string | null>(null);
	/** Concurrent-edit notice (LWW recovery, classic parity). */
	let conflictNotice = $state<string | null>(null);

	let renaming = $state(false);
	let titleDraft = $state('');
	let confirmingTrash = $state(false);

	let saveTimer: ReturnType<typeof setTimeout> | null = null;

	/** Bumped on every editor change so an open outline tracks live edits. */
	let editorRevision = $state(0);
	let openingChat = $state(false);
	/** Chat docked beside the page (classic: page primary, chat companion). */
	let chatConversationId = $state<string | null>(null);
	/** Revision-armed selection hand-off from the editor bubble to the chat. */
	let chatInsert = $state({ text: '', revision: 0 });

	/** Activity-tab version viewer (classic view_version overlay). */
	let viewingVersion = $state<PageVersionDiff | null>(null);
	let restoring = $state(false);

	async function viewVersion(versionId: string) {
		if (!pageData) return;
		const result = await brainPageVersionDiff(pageData.id, versionId);
		if (result.success) viewingVersion = result.data;
	}

	/**
	 * Restore writes the snapshot through the standard optimistic-lock body
	 * path, so the editor-level policy applies and the restore itself shows
	 * up in the version history (classic behavior).
	 */
	async function restoreVersion() {
		if (!pageData || !viewingVersion || restoring) return;
		restoring = true;
		const id = pageData.id;

		const body = await brainPageVersionBody(id, viewingVersion.versionId);
		if (body.success && id === pageId) {
			const result = await updateBrainPageBody(id, body.data, lockVersion);
			if (result.status === 'saved' && id === pageId) {
				lockVersion = result.page.lockVersion;
				const refreshed = await getBrainPageForEdit(id);
				if (refreshed.success && id === pageId) {
					pageData = refreshed.data;
					lockVersion = refreshed.data.lockVersion;
					dirty = false;
					editorRef?.setContent(refreshed.data.prosemirror);
					void refreshFileBlocks(id, refreshed.data.body);
				}
				viewingVersion = null;
			} else if (result.status !== 'saved') {
				saveError =
					result.status === 'conflict'
						? 'This page changed elsewhere — reopen the version and try again.'
						: result.message;
			}
		}
		restoring = false;
	}

	async function toggleChat() {
		if (!pageData || openingChat) return;
		if (chatConversationId) {
			chatConversationId = null;
			return;
		}
		openingChat = true;
		const result = await openCompanionChat('brain_page', pageData.id);
		if (result.success) chatConversationId = result.data.conversationId;
		openingChat = false;
	}

	/**
	 * Editor bubble "Ask"/"Refine": send the selection to the docked chat's
	 * composer (opening the chat first if needed). Refine prefixes the typed
	 * instruction. Matches the classic ask/refine transport (selection → agent).
	 */
	async function onBubbleAction(event: string, payload: Record<string, unknown>) {
		const selection = typeof payload.text === 'string' ? payload.text.trim() : '';
		if (!selection || !pageData) return;
		const instruction = typeof payload.instruction === 'string' ? payload.instruction.trim() : '';
		const text = event === 'refine' && instruction ? `${instruction}:\n\n${selection}` : selection;

		if (!chatConversationId) {
			const result = await openCompanionChat('brain_page', pageData.id);
			if (!result.success) return;
			chatConversationId = result.data.conversationId;
		}
		chatInsert = { text, revision: chatInsert.revision + 1 };
	}

	// Resolve the files referenced by the page body into the global map the
	// editor's File/Image NodeViews render from, then re-render the doc so those
	// blocks swap from the "no longer available" placeholder to the real file.
	// Only re-renders when the body actually references files (no flash / no
	// cost on file-less pages) and never clobbers an in-progress edit.
	async function refreshFileBlocks(id: string, body: string | null | undefined) {
		const hasFiles = extractBrainFileIds(body).length > 0;
		await populateBrainFileMap(id, body);
		if (hasFiles && id === pageId && !dirty) {
			editorRef?.setContent(pageData?.prosemirror ?? {});
		}
	}

	// Derived so the channel effect tracks the VALUE, not the object.
	const brainId = $derived(pageData?.brain.id ?? null);

	// One-shot: deep links sync the nav once; afterwards the mode strip
	// may switch the nav freely without this route forcing it back.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'brain') void workbench.setMode('brain');
	});

	$effect(() => {
		const id = pageId;
		pageData = null;
		chatConversationId = null;
		viewingVersion = null;
		loadError = null;
		saveError = null;
		conflictNotice = null;
		confirmingTrash = false;
		dirty = false;
		saveState = 'idle';

		void getBrainPageForEdit(id).then((result) => {
			if (id !== pageId) return;
			if (result.success) {
				pageData = result.data;
				lockVersion = result.data.lockVersion;
				void refreshFileBlocks(id, result.data.body);
				void brainPages(result.data.brain.id).then((pagesResult) => {
					if (id === pageId && pagesResult.success) siblingPages = pagesResult.data;
				});
			} else {
				loadError = result.errors[0]?.message ?? 'Page could not be loaded';
			}
		});
		void listPageBacklinks(id).then((result) => {
			if (id === pageId && result.success) backlinks = result.data;
		});

		return () => {
			if (saveTimer) clearTimeout(saveTimer);
			clearBrainFileMap(id);
		};
	});

	// Live updates from the brain channel: other actors' saves reload the
	// document in place when we're clean; when dirty, the next autosave
	// applies last-write-wins (classic behavior) and we note the overwrite.
	$effect(() => {
		const id = pageId;
		if (!brainId) return;

		let cancelled = false;
		let leave: (() => void) | null = null;

		void joinBrainUpdates(brainId, (update) => {
			if (update.event === 'page.body_updated' && update.pageId === id) {
				if (update.actorId && update.actorId === session.user?.id) return;
				if (dirty) {
					conflictNotice =
						'Someone else is editing this page — your next save will overwrite their changes.';
				} else {
					void getBrainPageForEdit(id).then((result) => {
						if (id !== pageId || !result.success) return;
						pageData = result.data;
						lockVersion = result.data.lockVersion;
						editorRef?.setContent(result.data.prosemirror);
						void refreshFileBlocks(id, result.data.body);
					});
				}
			}
			if (['page.created', 'page.updated', 'page.deleted'].includes(update.event)) {
				void brainNav.reloadTree();
			}
		}).then((cleanup) => {
			if (cancelled) cleanup();
			else leave = cleanup;
		});

		return () => {
			cancelled = true;
			leave?.();
		};
	});

	function scheduleSave() {
		dirty = true;
		editorRevision += 1;
		if (saveTimer) clearTimeout(saveTimer);
		saveTimer = setTimeout(() => void save(), 1000);
	}

	async function save(retrying = false) {
		const doc = editorRef?.getJSON();
		if (!pageData || !doc) return;

		saveState = 'saving';
		saveError = null;
		const id = pageData.id;

		const result = await saveBrainPageProsemirror(id, doc, lockVersion);
		if (id !== pageId) return;

		if (result.status === 'saved') {
			lockVersion = result.lockVersion;
			dirty = false;
			saveState = 'saved';
			return;
		}

		if (result.status === 'conflict' && !retrying) {
			// LWW recovery: adopt the server's version and resave the local
			// document on top of it (the classic editor's behavior).
			const refreshed = await getBrainPageForEdit(id);
			if (id !== pageId) return;
			lockVersion = result.currentVersion ?? (refreshed.success ? refreshed.data.lockVersion : 0);
			conflictNotice = 'This page changed elsewhere — your version was saved over it.';
			await save(true);
			return;
		}

		saveState = 'error';
		saveError = result.message;
	}

	async function commitRename() {
		if (!renaming || !pageData) return;
		renaming = false;
		const title = titleDraft.trim();
		if (!title || title === pageData.title) return;
		const result = await renameBrainPage(pageData.id, title);
		if (result.success) {
			pageData = { ...pageData, title: result.data.title };
			void brainNav.reloadTree();
		}
	}

	async function trash() {
		if (!pageData) return;
		if (!confirmingTrash) {
			confirmingTrash = true;
			setTimeout(() => (confirmingTrash = false), 3000);
			return;
		}
		const result = await trashBrainPage(pageData.id);
		if (result.success) {
			void brainNav.reloadTree();
			await goto(`${base}/brain`);
		}
	}

	function openPageByTitle(title: string) {
		const target = siblingPages.find((sibling) => sibling.title === title);
		if (target) void goto(`${base}/brain/page/${target.id}`);
	}
</script>

<svelte:head>
	<title>Magus — {pageData?.title ?? 'Brain'}</title>
</svelte:head>

<!-- Mobile takeover (mirrors the chat companion host): when the chat is docked,
     below md it goes full-width and the editor pane + handle are hidden
     (display:none, so the editor stays mounted). The editor's "Open chat" pill
     and the bubble Ask/Refine surface the chat; its own close returns here. -->
<Resizable.PaneGroup direction="horizontal" autoSaveId="magus:brain-chat-split">
	<Resizable.Pane defaultSize={60} minSize={35} class={chatConversationId ? 'max-md:hidden' : ''}>
		<div class="flex h-full min-h-0 flex-col" data-testid="brain-page">
			{#if loadError}
				<p class="p-6 text-sm text-destructive">{loadError}</p>
			{:else if !pageData}
				<!-- Quiet load: full header chrome (title from the nav tree) over
				     the bare editor surface — pulsing skeleton bars flickered on
				     every navigation since loads are sub-second. -->
				<header
					class="flex min-h-11 shrink-0 items-center gap-2 border-b bg-background/80 py-2 px-6 backdrop-blur-sm"
				>
					<MobileNavButton />
					{#if navNode?.icon}
						<span class="shrink-0 text-base leading-none">{navNode.icon}</span>
					{:else}
						<NotebookPen class="size-4 shrink-0 text-muted-foreground" />
					{/if}
					<span class="min-w-0 flex-1 truncate text-base font-semibold">
						{navNode?.title ?? ''}
					</span>
					<div class="flex shrink-0 items-center gap-1.5">
						<button type="button" class="wb-pill-btn shrink-0" disabled>
							<MessageSquare class="size-3.5" />
							<span>Open chat</span>
						</button>
						<button type="button" class="wb-pill-btn wb-pill-btn-square shrink-0" disabled>
							<Trash2 class="size-3.5" />
						</button>
					</div>
				</header>
				<div class="min-h-0 flex-1 bg-card"></div>
			{:else}
				<header
					class="flex min-h-11 shrink-0 items-center gap-2 border-b bg-background/80 py-2 px-6 backdrop-blur-sm"
				>
					<MobileNavButton />
					{#if pageData.icon}
						<span class="shrink-0 text-base leading-none">{pageData.icon}</span>
					{:else}
						<NotebookPen class="size-4 shrink-0 text-muted-foreground" />
					{/if}
					{#if renaming}
						<!-- svelte-ignore a11y_autofocus — transient rename input -->
						<input
							bind:value={titleDraft}
							autofocus
							data-testid="brain-page-title-input"
							class="min-w-0 flex-1 rounded-md border border-input bg-secondary px-2 py-1 text-sm font-semibold outline-none focus:border-primary/60"
							onblur={() => void commitRename()}
							onkeydown={(event) => {
								if (event.key === 'Enter') void commitRename();
								if (event.key === 'Escape') renaming = false;
							}}
						/>
					{:else}
						<button
							type="button"
							class="min-w-0 flex-1 truncate text-left text-base font-semibold hover:underline"
							data-testid="brain-page-title"
							title="Rename page"
							onclick={() => {
								titleDraft = pageData?.title ?? '';
								renaming = true;
							}}
						>
							{pageData.title ?? 'Untitled page'}
						</button>
					{/if}
					<span class="shrink-0 text-xs text-muted-foreground" data-testid="brain-save-state">
						{#if saveState === 'saving'}
							Saving…
						{:else if dirty}
							Unsaved changes
						{:else if saveState === 'saved'}
							Saved
						{:else}
							Updated {relativeTime(pageData.updatedAt)}
						{/if}
					</span>
					<PresenceAvatars viewers={presence.viewers} selfUserId={session.user?.id} max={3} />
					<div class="flex shrink-0 items-center gap-1.5">
						<button
							type="button"
							class="wb-pill-btn shrink-0"
							data-testid="brain-add-file"
							onclick={() => (filePickerOpen = true)}
						>
							<Paperclip class="size-3.5" />
							<span>Add file</span>
						</button>
						<button
							type="button"
							class="wb-pill-btn shrink-0 {chatConversationId ? 'wb-pill-btn-active' : ''}"
							data-testid="brain-open-chat"
							disabled={openingChat}
							onclick={() => void toggleChat()}
						>
							<MessageSquare class="size-3.5" />
							<span>{chatConversationId ? 'Close chat' : 'Open chat'}</span>
						</button>
						<button
							type="button"
							class="wb-pill-btn wb-pill-btn-square shrink-0 {confirmingTrash
								? '!border-destructive !bg-destructive !text-destructive-foreground'
								: 'hover:!text-destructive'}"
							aria-label={confirmingTrash ? 'Confirm trash' : 'Move to trash'}
							onclick={() => void trash()}
						>
							<Trash2 class="size-3.5" />
						</button>
					</div>
				</header>

				{#if conflictNotice}
					<p
						class="border-b bg-warning/10 px-6 py-1.5 text-xs text-warning"
						data-testid="brain-page-conflict"
					>
						{conflictNotice}
					</p>
				{/if}
				{#if saveError}
					<p class="border-b bg-destructive/10 px-6 py-1.5 text-xs text-destructive">{saveError}</p>
				{/if}

				<!-- Classic: the editor surface sits on wb-surface (our card token),
		     visibly separated from the surrounding wb-bg pane. -->
				<div class="relative min-h-0 flex-1">
					<div class="wb-scroll h-full overflow-y-auto bg-card">
						<div class="mx-auto max-w-3xl px-6 py-5">
							{#key pageData.id}
								<!-- data-page-id is the anchor the File/Image NodeViews use
								     to resolve their page's window.__brainFileMaps entry. -->
								<div data-page-id={pageData.id}>
									<BrainEditor
										bind:this={editorRef}
										content={pageData.prosemirror}
										pages={siblingPages}
										pageId={pageData.id}
										workspaceId={pageData.brain.workspaceId}
										onChange={scheduleSave}
										onPageRefClick={openPageByTitle}
										onUploadError={(message) => (saveError = message)}
										{onBubbleAction}
									/>
								</div>
							{/key}
						</div>
					</div>
					{#if viewingVersion}
						<VersionDiffOverlay
							diff={viewingVersion}
							{restoring}
							onClose={() => (viewingVersion = null)}
							onRestore={() => void restoreVersion()}
						/>
					{/if}
				</div>

				<BrainBottomBar
					pageId={pageData.id}
					{backlinks}
					revision={editorRevision}
					getDoc={() => editorRef?.getJSON() ?? pageData?.prosemirror ?? null}
					onViewVersion={(versionId) => void viewVersion(versionId)}
				/>

				<!-- Content pages dock a collapsible task bar below the editor: the
				     document stays on top, the bar's header is always visible, and
				     its body (the kanban/list board) claims up to ~55% of the pane
				     with its own scroll when expanded. -->
				{#if pageData.kind === 'page'}
					<!-- brainId is non-null here: this branch only renders once pageData
					     (which seeded brainId) has loaded, matching the pageId! precedent above. -->
					<TaskBottomBar brainId={brainId!} brainPageId={pageData.id} />
				{/if}

				<BrainFilePickerDialog
					bind:open={filePickerOpen}
					workspaceId={pageData.brain.workspaceId}
					onPick={(file) => editorRef?.insertExistingFile(file)}
				/>
			{/if}
		</div>
	</Resizable.Pane>
	{#if chatConversationId}
		<Resizable.Handle class="max-md:hidden" />
		<Resizable.Pane defaultSize={40} minSize={25}>
			{#await loadConversationCompanion() then { default: ConversationCompanion }}
				<ConversationCompanion
					conversationId={chatConversationId}
					insert={chatInsert}
					onClose={() => (chatConversationId = null)}
				/>
			{/await}
		</Resizable.Pane>
	{/if}
</Resizable.PaneGroup>
