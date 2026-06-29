<script lang="ts">
	import { page } from '$app/state';
	import type { CompanionSpec } from '$lib/ash/api';
	import { ConversationStore } from '$lib/chat/conversation-store.svelte';
	import { takePendingMessage } from '$lib/chat/pending-message';
	import CompanionHost from '$lib/components/companions/companion-host.svelte';
	import ConversationView from '$lib/components/chat/conversation-view.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';

	const conversationId = $derived(page.params.conversationId!);
	// Search deep-links carry ?highlight=<messageId> to flash + scroll to a hit.
	const highlightMessageId = $derived(page.url.searchParams.get('highlight'));

	// The page owns the store so the companion host (split-pane chrome around
	// the conversation) can react to its channel events too.
	let store = $state<ConversationStore | null>(null);

	$effect(() => {
		const instance = new ConversationStore(conversationId);
		instance.onCompanionRequest = (spec) => openCompanion(instance.conversationId, spec);
		store = instance;
		void instance.start().then(() => {
			// New-chat hand-off: the landing page deferred creation, stashed the
			// first message, and navigated here. Send it now that history has
			// loaded (no optimistic-bubble clobber) and the channel join is under
			// way, so the agent's first response streams in. Skip if a fast
			// conversation switch already replaced this store.
			if (store !== instance) return;
			const pending = takePendingMessage(instance.conversationId);
			if (pending) void instance.send(pending.text, pending.resources);
		});
		return () => instance.stop();
	});

	// Deep links open/focus a tab once the shell state is loaded. Guarded so
	// session updates from the open/activate round trip don't re-trigger it.
	$effect(() => {
		const session = workbench.session;
		if (!session || !conversationId) return;

		const existing = session.tabs.find(
			(tab) => tab.primary.type === 'conversation' && tab.primary.id === conversationId
		);
		if (existing && session.activeTabId === existing.id) return;

		void workbench.openTab({ type: 'conversation', id: conversationId });
	});

	const tab = $derived(workbench.tabForConversation(conversationId));

	function openCompanion(forConversationId: string, spec: CompanionSpec) {
		const target = workbench.tabForConversation(forConversationId);
		if (target) void workbench.setCompanion(target.id, spec);
	}
</script>

<svelte:head>
	<title>Magus — {workbench.conversationTitle(conversationId)}</title>
</svelte:head>

{#key conversationId}
	{#if store}
		<CompanionHost
			tabId={tab?.id ?? null}
			companion={tab?.companion ?? null}
			draftRevision={store.draftRevision}
			brainRevision={store.brainRevision}
		>
			<ConversationView
				{store}
				{highlightMessageId}
				onCompanionRequest={(spec) => openCompanion(conversationId, spec)}
			/>
		</CompanionHost>
	{/if}
{/key}
