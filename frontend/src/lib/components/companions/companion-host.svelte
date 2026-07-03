<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { CompanionSpec } from '$lib/ash/api';
	import type { ComposerSelection } from '$lib/chat/conversation-store.svelte';
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
		onInsertText,
		onSelection,
		children
	}: {
		tabId: string | null;
		companion: CompanionSpec | null;
		draftRevision?: number;
		brainRevision?: number;
		/** Drops text (e.g. a Refine instruction) into the primary conversation composer. */
		onInsertText?: (text: string) => void;
		/** Pins an Ask selection / PDF screenshot as a composer context pill. */
		onSelection?: (selection: ComposerSelection) => void;
		children: Snippet;
	} = $props();

	// String key so the effect-free derived chain doesn't re-render the
	// primary pane on unrelated companion object identity changes.
	const companionKey = $derived(companion ? `${companion.type}:${companion.id}` : null);

	/**
	 * Below md the split collapses to one pane at a time. A fresh companion
	 * takes over ('companion'); the switcher bar flips back to the primary
	 * view without closing the companion. md+ shows both panes and ignores it.
	 */
	let mobileView = $state<'primary' | 'companion'>('companion');
	$effect(() => {
		if (companionKey) mobileView = 'companion';
	});

	const COMPANION_LABELS: Record<string, string> = {
		brain_page: 'Page',
		thread: 'Thread',
		conversation: 'Chat',
		pdf: 'PDF',
		draft: 'Draft',
		service: 'Preview',
		tasks: 'Tasks',
		spreadsheet: 'Sheet'
	};
	const companionLabel = $derived(companion ? (COMPANION_LABELS[companion.type] ?? 'Pane') : '');

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
     primary stays mounted). The switcher bar above flips which pane shows
     without closing the companion. -->
<div class="flex h-full min-h-0 flex-col">
	{#if companion && tabId}
		<!-- Mobile pane switcher. min-h-11 matches the shared pane-header
		     height; pl-14 clears the floating nav toggle. -->
		<div
			class="flex min-h-11 shrink-0 items-center gap-1.5 border-b py-2 pr-4 pl-14 md:hidden"
			data-testid="companion-mobile-switcher"
		>
			<button
				type="button"
				class="wb-pill-btn {mobileView === 'primary' ? 'wb-pill-btn-active' : ''}"
				data-testid="mobile-switch-primary"
				onclick={() => (mobileView = 'primary')}
			>
				Chat
			</button>
			<button
				type="button"
				class="wb-pill-btn {mobileView === 'companion' ? 'wb-pill-btn-active' : ''}"
				data-testid="mobile-switch-companion"
				onclick={() => (mobileView = 'companion')}
			>
				{companionLabel}
			</button>
		</div>
	{/if}

	<Resizable.PaneGroup direction="horizontal" autoSaveId="magus:companion-split">
		<Resizable.Pane
			defaultSize={55}
			minSize={30}
			class={companion && tabId && mobileView === 'companion' ? 'max-md:hidden' : ''}
		>
			{@render children()}
		</Resizable.Pane>
		{#if companion && tabId}
			<Resizable.Handle class="max-md:hidden" />
			<Resizable.Pane
				defaultSize={45}
				minSize={25}
				class={mobileView === 'primary' ? 'max-md:hidden' : ''}
			>
				{#key companionKey}
					{#if companion.type === 'brain_page'}
						<BrainPageCompanion
							pageId={companion.id}
							revision={brainRevision}
							onClose={close}
							onOpenPage={openPage}
							onAsk={onInsertText}
							onAskSelection={onSelection
								? (selection) => onSelection({ kind: 'brain', ...selection })
								: undefined}
						/>
					{:else if companion.type === 'thread'}
						<ThreadCompanion threadId={companion.id} onClose={close} />
					{:else if companion.type === 'conversation'}
						{#await loadConversationCompanion() then { default: ConversationCompanion }}
							<ConversationCompanion conversationId={companion.id} onClose={close} />
						{/await}
					{:else if companion.type === 'pdf'}
						<PdfCompanion
							spec={companion}
							onClose={close}
							onAskSelection={onSelection
								? (selection) => onSelection({ kind: 'pdf', ...selection })
								: undefined}
						/>
					{:else if companion.type === 'service'}
						<ServiceCompanion spec={companion} onClose={close} />
					{:else if companion.type === 'tasks'}
						<TasksCompanion conversationId={companion.id} onClose={close} />
					{:else if companion.type === 'draft'}
						{#await loadDraftCompanion() then { default: DraftCompanion }}
							<DraftCompanion
								draftId={companion.id}
								revision={draftRevision}
								onClose={close}
								onAsk={onInsertText}
								onAskSelection={onSelection
									? (selection) => onSelection({ kind: 'draft', ...selection })
									: undefined}
							/>
						{/await}
					{:else}
						<ClassicCompanion spec={companion} onClose={close} />
					{/if}
				{/key}
			</Resizable.Pane>
		{/if}
	</Resizable.PaneGroup>
</div>
