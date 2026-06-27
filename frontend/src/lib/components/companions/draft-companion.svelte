<script lang="ts">
	import { FileText } from '@lucide/svelte';
	import { getDraft, renameDraft, updateDraftContent, type DraftDetail } from '$lib/ash/api';
	import { relativeTime } from '$lib/time';
	import BrainEditor from '$lib/components/brain/brain-editor.svelte';
	import PresenceAvatars from '$lib/components/chat/presence-avatars.svelte';
	import { ResourcePresence } from '$lib/chat/resource-presence.svelte';
	import { session } from '$lib/stores/session.svelte';
	import CompanionFrame from './companion-frame.svelte';

	let {
		draftId,
		revision = 0,
		onClose
	}: {
		draftId: string;
		/** Bumped by the conversation store on draft.* channel events. */
		revision?: number;
		onClose: () => void;
	} = $props();

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

	$effect(() => {
		const id = draftId;
		draft = null;
		loadError = null;
		saveError = null;
		conflictNotice = null;
		dirty = false;
		saveState = 'idle';

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
		<PresenceAvatars viewers={presence.viewers} selfUserId={session.user?.id} max={3} />
	{/snippet}

	{#if conflictNotice}
		<p class="border-b bg-warning/10 px-4 py-1.5 text-xs text-warning" data-testid="draft-conflict">
			{conflictNotice}
		</p>
	{/if}
	{#if saveError}
		<p class="border-b bg-destructive/10 px-4 py-1.5 text-xs text-destructive">{saveError}</p>
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
			{#key draft.id}
				<BrainEditor bind:this={editorRef} content={draft.content} onChange={scheduleSave} />
			{/key}
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
