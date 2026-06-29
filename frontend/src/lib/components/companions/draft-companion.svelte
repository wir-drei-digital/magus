<script lang="ts">
	import { ArrowLeft, ChevronDown, Download, FileText, History, RotateCcw } from '@lucide/svelte';
	import {
		draftVersions,
		exportDraft,
		getDraft,
		renameDraft,
		restoreDraftVersion,
		updateDraftContent,
		type DraftDetail,
		type DraftExportFormat,
		type DraftVersion
	} from '$lib/ash/api';
	import { relativeTime } from '$lib/time';
	import { bubbleSelectionText } from '$lib/chat/bubble-action';
	import BrainEditor from '$lib/components/brain/brain-editor.svelte';
	import PresenceAvatars from '$lib/components/chat/presence-avatars.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import { ResourcePresence } from '$lib/chat/resource-presence.svelte';
	import { session } from '$lib/stores/session.svelte';
	import CompanionFrame from './companion-frame.svelte';

	let {
		draftId,
		revision = 0,
		onClose,
		onAsk
	}: {
		draftId: string;
		/** Bumped by the conversation store on draft.* channel events. */
		revision?: number;
		onClose: () => void;
		/** Editor bubble Ask/Refine: drop the selection into the conversation composer. */
		onAsk?: (text: string) => void;
	} = $props();

	function onBubbleAction(event: string, payload: Record<string, unknown>) {
		const text = bubbleSelectionText(event, payload);
		if (text) onAsk?.(text);
	}

	// Live co-viewers on this draft's shared presence topic (SPA + classic).
	const presence = new ResourcePresence();
	$effect(() => {
		void presence.start('draft', draftId);
		return () => presence.stop();
	});

	let draft = $state<DraftDetail | null>(null);
	let loadError = $state<string | null>(null);

	let editorRef = $state<BrainEditor | null>(null);
	let version = $state(0);
	let dirty = $state(false);
	let saveState = $state<'idle' | 'saving' | 'saved' | 'error'>('idle');
	let saveError = $state<string | null>(null);
	let conflictNotice = $state<string | null>(null);

	let saveTimer: ReturnType<typeof setTimeout> | null = null;
	// Bumped to force the editable editor to recreate with fresh content (e.g.
	// after a version restore), since BrainEditor reads `content` only on mount.
	let reloadKey = $state(0);

	// Document / version-history view + read-only preview of a single version.
	let view = $state<'document' | 'history'>('document');
	let versions = $state<DraftVersion[]>([]);
	let versionsLoading = $state(false);
	let versionsError = $state<string | null>(null);
	let previewVersion = $state<DraftVersion | null>(null);

	let exporting = $state<DraftExportFormat | null>(null);
	let exportNotice = $state<string | null>(null);
	let restoring = $state<string | null>(null);

	const EXPORT_FORMATS: { format: DraftExportFormat; label: string }[] = [
		{ format: 'pdf', label: 'PDF' },
		{ format: 'docx', label: 'Word (.docx)' },
		{ format: 'latex', label: 'LaTeX' },
		{ format: 'markdown', label: 'Markdown' }
	];

	const VERSION_ACTION_LABELS: Record<string, string> = {
		create: 'Created',
		update_content: 'Edited',
		update_content_json: 'Edited',
		update_title: 'Renamed',
		replace_text: 'Text replaced',
		restore_version: 'Restored'
	};
	const versionLabel = (action: string) => VERSION_ACTION_LABELS[action] ?? 'Updated';

	$effect(() => {
		const id = draftId;
		draft = null;
		loadError = null;
		saveError = null;
		conflictNotice = null;
		dirty = false;
		saveState = 'idle';
		view = 'document';
		previewVersion = null;
		exportNotice = null;

		void getDraft(id).then((result) => {
			if (id !== draftId) return;
			if (result.success) {
				draft = result.data;
				version = result.data.version;
			} else {
				loadError = result.errors[0]?.message ?? 'Draft could not be loaded';
			}
		});

		return () => {
			if (saveTimer) clearTimeout(saveTimer);
		};
	});

	// Channel events bump `revision` for every draft change — including the
	// echo of our own saves. The version check tells them apart: an echo
	// carries the version we already adopted from the save response.
	let revisionArmed = false;
	$effect(() => {
		void revision;
		if (!revisionArmed) {
			revisionArmed = true;
			return;
		}
		const id = draftId;
		void getDraft(id).then((result) => {
			if (id !== draftId || !result.success || !draft) return;
			if (result.data.version === version) return;
			if (dirty) {
				conflictNotice =
					'This draft changed elsewhere — your next save will overwrite those changes.';
				version = result.data.version;
			} else {
				draft = result.data;
				version = result.data.version;
				editorRef?.setContent(result.data.content);
			}
		});
	});

	function scheduleSave() {
		dirty = true;
		if (saveTimer) clearTimeout(saveTimer);
		saveTimer = setTimeout(() => void save(), 1000);
	}

	async function save() {
		const doc = editorRef?.getJSON();
		if (!draft || !doc) return;

		saveState = 'saving';
		saveError = null;
		const id = draft.id;

		const result = await updateDraftContent(id, doc);
		if (id !== draftId) return;

		if (result.success) {
			version = result.data.version;
			dirty = false;
			saveState = 'saved';
			conflictNotice = null;
		} else {
			saveState = 'error';
			saveError = result.errors[0]?.message ?? 'Draft could not be saved';
		}
	}

	async function rename(title: string) {
		if (!draft) return;
		const result = await renameDraft(draft.id, title);
		if (result.success) draft = { ...draft, title: result.data.title };
	}

	async function loadVersions() {
		if (!draft) return;
		versionsLoading = true;
		versionsError = null;
		const result = await draftVersions(draft.id);
		if (result.success) versions = result.data;
		else versionsError = result.errors[0]?.message ?? 'Could not load versions';
		versionsLoading = false;
	}

	async function showHistory() {
		// Flush a pending edit so the latest content is captured as a version.
		if (saveTimer) clearTimeout(saveTimer);
		if (dirty) await save();
		view = 'history';
		previewVersion = null;
		void loadVersions();
	}

	function showDocument() {
		view = 'document';
		previewVersion = null;
	}

	async function runExport(format: DraftExportFormat) {
		if (!draft) return;
		exporting = format;
		exportNotice = null;
		const result = await exportDraft(draft.id, draft.conversationId, format);
		exporting = null;
		exportNotice = result.success
			? 'Export started. It will appear in the conversation.'
			: (result.errors[0]?.message ?? 'Export failed');
	}

	async function restore(versionId: string) {
		if (!draft) return;
		restoring = versionId;
		const result = await restoreDraftVersion(draft.id, versionId);
		restoring = null;
		if (result.success) {
			draft = {
				...draft,
				title: result.data.title,
				content: result.data.content,
				version: result.data.version,
				updatedAt: result.data.updatedAt
			};
			version = result.data.version;
			dirty = false;
			saveState = 'idle';
			reloadKey += 1;
			showDocument();
		} else {
			versionsError = result.errors[0]?.message ?? 'Restore failed';
		}
	}
</script>

<CompanionFrame
	title={draft?.title ?? 'Draft'}
	meta={draft ? `v${version} · ${relativeTime(draft.updatedAt)}` : null}
	{onClose}
	onRename={(title) => void rename(title)}
>
	{#snippet icon()}
		<FileText class="size-4 shrink-0 text-muted-foreground" />
	{/snippet}

	{#snippet headerActions()}
		<div class="flex items-center gap-1">
			<PresenceAvatars viewers={presence.viewers} selfUserId={session.user?.id} max={3} />

			<DropdownMenu.Root>
				<DropdownMenu.Trigger
					class="inline-flex items-center gap-1 rounded-lg px-2 py-1.5 text-xs font-medium text-secondary-foreground transition-colors hover:bg-accent/60 hover:text-foreground disabled:opacity-50"
					disabled={!draft || exporting !== null}
					data-testid="draft-export"
				>
					<Download class="size-3.5" />
					<span class="max-md:hidden">Export</span>
					<ChevronDown class="size-3" />
				</DropdownMenu.Trigger>
				<DropdownMenu.Content align="end" class="w-40 p-1">
					{#each EXPORT_FORMATS as fmt (fmt.format)}
						<DropdownMenu.Item
							onSelect={() => void runExport(fmt.format)}
							data-testid="draft-export-{fmt.format}"
						>
							{fmt.label}
						</DropdownMenu.Item>
					{/each}
				</DropdownMenu.Content>
			</DropdownMenu.Root>

			<button
				type="button"
				class="inline-flex items-center gap-1 rounded-lg px-2 py-1.5 text-xs font-medium transition-colors hover:bg-accent/60 hover:text-foreground {view ===
				'history'
					? 'bg-accent/60 text-foreground'
					: 'text-secondary-foreground'}"
				data-testid="draft-history-toggle"
				onclick={() => (view === 'history' ? showDocument() : void showHistory())}
			>
				<History class="size-3.5" />
				<span class="max-md:hidden">{view === 'history' ? 'Editor' : 'History'}</span>
			</button>
		</div>
	{/snippet}

	{#if conflictNotice}
		<p class="border-b bg-warning/10 px-4 py-1.5 text-xs text-warning" data-testid="draft-conflict">
			{conflictNotice}
		</p>
	{/if}
	{#if saveError}
		<p class="border-b bg-destructive/10 px-4 py-1.5 text-xs text-destructive">{saveError}</p>
	{/if}
	{#if exportNotice}
		<p
			class="border-b bg-accent/40 px-4 py-1.5 text-xs text-foreground"
			data-testid="draft-export-notice"
		>
			{exportNotice}
		</p>
	{/if}

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto bg-card px-5 py-4" data-testid="draft-body">
		{#if loadError}
			<p class="text-sm text-destructive">{loadError}</p>
		{:else if !draft}
			<div class="space-y-3">
				<div class="h-5 w-1/2 animate-pulse rounded bg-muted"></div>
				<div class="h-4 w-full animate-pulse rounded bg-muted"></div>
			</div>
		{:else}
			<!-- The editable editor stays mounted (just hidden) while browsing
			     history, so its content/cursor and the autosave timer survive. -->
			<div class:hidden={view === 'history' || previewVersion !== null}>
				{#key `${draft.id}:${reloadKey}`}
					<BrainEditor
						bind:this={editorRef}
						content={draft.content}
						onChange={scheduleSave}
						{onBubbleAction}
					/>
				{/key}
			</div>

			{#if previewVersion}
				<div data-testid="draft-version-preview">
					<div
						class="mb-3 flex items-center justify-between gap-2 rounded-lg border bg-warning/10 px-3 py-2"
					>
						<span class="text-xs text-warning">
							Viewing {versionLabel(previewVersion.action)} · {previewVersion.insertedAt
								? relativeTime(previewVersion.insertedAt)
								: ''} (read-only)
						</span>
						<div class="flex shrink-0 items-center gap-1">
							<button
								type="button"
								class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-accent"
								onclick={() => (previewVersion = null)}
							>
								<ArrowLeft class="size-3" /> Back
							</button>
							<button
								type="button"
								class="inline-flex items-center gap-1 rounded-md bg-primary px-2 py-1 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
								disabled={restoring === previewVersion.id}
								data-testid="draft-version-restore-preview"
								onclick={() => previewVersion && void restore(previewVersion.id)}
							>
								<RotateCcw class="size-3" /> Restore
							</button>
						</div>
					</div>
					{#key previewVersion.id}
						<BrainEditor
							content={previewVersion.content ?? draft.content}
							editable={false}
							onChange={() => {}}
						/>
					{/key}
				</div>
			{:else if view === 'history'}
				<div data-testid="draft-version-list">
					{#if versionsLoading}
						<div class="space-y-2">
							{#each [1, 2, 3] as i (i)}
								<div class="h-10 w-full animate-pulse rounded bg-muted"></div>
							{/each}
						</div>
					{:else if versionsError}
						<p class="text-sm text-destructive">{versionsError}</p>
					{:else if versions.length === 0}
						<p class="text-sm text-muted-foreground">No earlier versions yet.</p>
					{:else}
						<ul class="space-y-1">
							{#each versions as v (v.id)}
								<li
									class="flex items-center justify-between gap-2 rounded-lg border px-3 py-2"
									data-testid="draft-version-row"
								>
									<div class="min-w-0">
										<p class="truncate text-sm font-medium">{versionLabel(v.action)}</p>
										<p class="text-xs text-muted-foreground">
											{v.insertedAt ? relativeTime(v.insertedAt) : ''}
										</p>
									</div>
									<div class="flex shrink-0 items-center gap-1">
										<button
											type="button"
											class="rounded-md px-2 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
											data-testid="draft-version-view"
											onclick={() => (previewVersion = v)}
										>
											View
										</button>
										<button
											type="button"
											class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-accent disabled:opacity-50"
											disabled={restoring === v.id}
											data-testid="draft-version-restore"
											onclick={() => void restore(v.id)}
										>
											<RotateCcw class="size-3" /> Restore
										</button>
									</div>
								</li>
							{/each}
						</ul>
					{/if}
				</div>
			{/if}
		{/if}
	</div>

	{#snippet footer()}
		<div class="flex shrink-0 items-center justify-end border-t px-4 py-2">
			<span class="text-[11px] text-muted-foreground" data-testid="draft-save-state">
				{#if saveState === 'saving'}
					Saving…
				{:else if dirty}
					Unsaved changes
				{:else if saveState === 'saved'}
					Saved
				{:else}
					Autosaves as you type
				{/if}
			</span>
		</div>
	{/snippet}
</CompanionFrame>
