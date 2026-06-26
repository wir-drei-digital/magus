<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { CompanionSpec } from '$lib/ash/api';
	import { workbench } from '$lib/stores/workbench.svelte';
	import * as Resizable from '$lib/components/ui/resizable';
	import BrainPageCompanion from './brain-page-companion.svelte';
	import ClassicCompanion from './classic-companion.svelte';
	import PdfCompanion from './pdf-companion.svelte';
	import ServiceCompanion from './service-companion.svelte';
	import TasksCompanion from './tasks-companion.svelte';
	import ThreadCompanion from './thread-companion.svelte';

	// Loaded on first open instead of imported statically: the draft
	// companion drags the whole TipTap editor stack into every route that
	// renders a companion host, and the conversation companion does the same
	// with the chat view for the brain/files routes.
	const loadDraftCompanion = () => import('./draft-companion.svelte');
	const loadConversationCompanion = () => import('./conversation-companion.svelte');

	let {
		tabId,
		companion,
		draftRevision = 0,
		brainRevision = 0,
		children
	}: {
		tabId: string | null;
		companion: CompanionSpec | null;
		draftRevision?: number;
		brainRevision?: number;
		children: Snippet;
	} = $props();

	// String key so the effect-free derived chain doesn't re-render the
	// primary pane on unrelated companion object identity changes.
	const companionKey = $derived(companion ? `${companion.type}:${companion.id}` : null);

	function close() {
		if (tabId) void workbench.setCompanion(tabId, null);
	}

	function openPage(pageId: string) {
		if (tabId) void workbench.setCompanion(tabId, { type: 'brain_page', id: pageId });
	}
</script>

<!-- The PaneGroup stays mounted with or without a companion so opening or
     closing one never remounts the primary pane (which would reset scroll
     position and reload its data).

     Mobile takeover (classic parity): below md a docked companion goes
     full-width and the primary pane + handle are hidden (display:none, so the
     primary stays mounted). With the primary collapsed, the companion pane is
     the sole flex-grower and fills the width on its own. -->
<Resizable.PaneGroup direction="horizontal" autoSaveId="magus:companion-split">
	<Resizable.Pane defaultSize={55} minSize={30} class={companion && tabId ? 'max-md:hidden' : ''}>
		{@render children()}
	</Resizable.Pane>
	{#if companion && tabId}
		<Resizable.Handle class="max-md:hidden" />
		<Resizable.Pane defaultSize={45} minSize={25}>
			{#key companionKey}
				{#if companion.type === 'brain_page'}
					<BrainPageCompanion
						pageId={companion.id}
						revision={brainRevision}
						onClose={close}
						onOpenPage={openPage}
					/>
				{:else if companion.type === 'thread'}
					<ThreadCompanion threadId={companion.id} onClose={close} />
				{:else if companion.type === 'conversation'}
					{#await loadConversationCompanion() then { default: ConversationCompanion }}
						<ConversationCompanion conversationId={companion.id} onClose={close} />
					{/await}
				{:else if companion.type === 'pdf'}
					<PdfCompanion spec={companion} onClose={close} />
				{:else if companion.type === 'service'}
					<ServiceCompanion spec={companion} onClose={close} />
				{:else if companion.type === 'tasks'}
					<TasksCompanion conversationId={companion.id} onClose={close} />
				{:else if companion.type === 'draft'}
					{#await loadDraftCompanion() then { default: DraftCompanion }}
						<DraftCompanion draftId={companion.id} revision={draftRevision} onClose={close} />
					{/await}
				{:else}
					<ClassicCompanion spec={companion} onClose={close} />
				{/if}
			{/key}
		</Resizable.Pane>
	{/if}
</Resizable.PaneGroup>
