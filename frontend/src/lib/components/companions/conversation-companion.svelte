<script lang="ts">
	import { tick } from 'svelte';
	import { MessagesSquare } from '@lucide/svelte';
	import { getConversation } from '$lib/ash/api';
	import { ConversationStore } from '$lib/chat/conversation-store.svelte';
	import Composer from '$lib/components/chat/composer.svelte';
	import MessageItem from '$lib/components/chat/message-item.svelte';
	import ToolCard from '$lib/components/chat/tool-card.svelte';
	import StreamingReasoning from '$lib/components/chat/streaming-reasoning.svelte';
	import { buildChatStream, toolViewFromLive } from '$lib/chat/events';
	import CompanionFrame from './companion-frame.svelte';

	let {
		conversationId,
		onClose,
		insert
	}: {
		conversationId: string;
		onClose: () => void;
		/**
		 * Revision-armed request to drop text into the composer (e.g. a brain
		 * page's bubble "Ask"/"Refine"). Bumping the revision re-inserts even
		 * with identical text; survives the store's async mount.
		 */
		insert?: { text: string; revision: number };
	} = $props();

	let store = $state<ConversationStore | null>(null);
	let title = $state('Chat');
	let scroller = $state<HTMLElement | null>(null);
	let stickToBottom = $state(true);

	$effect(() => {
		const instance = new ConversationStore(conversationId);
		store = instance;
		void instance.start();
		return () => instance.stop();
	});

	// Forward host insert requests to the composer once the store exists.
	let lastInsertRevision = 0;
	$effect(() => {
		if (!store || !insert || insert.revision === lastInsertRevision) return;
		lastInsertRevision = insert.revision;
		if (insert.text) store.requestInsertText(insert.text);
	});

	$effect(() => {
		const id = conversationId;
		void getConversation(id).then((result) => {
			if (id === conversationId && result.success && result.data.title) title = result.data.title;
		});
	});

	$effect(() => {
		if (!store) return;
		void store.messages;
		void store.liveTools;
		if (stickToBottom) {
			void tick().then(() => scroller?.scrollTo({ top: scroller.scrollHeight }));
		}
	});

	function onScroll() {
		if (!scroller) return;
		stickToBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
	}
</script>

<CompanionFrame {title} {onClose}>
	{#snippet icon()}
		<MessagesSquare class="size-4 shrink-0 text-muted-foreground" />
	{/snippet}

	{#if store}
		<div
			class="wb-scroll min-h-0 flex-1 overflow-y-auto px-4 py-3"
			bind:this={scroller}
			onscroll={onScroll}
			data-testid="conversation-companion-messages"
		>
			{#if store.loading && store.messages.length === 0}
				<div class="space-y-3">
					{#each [1, 2] as i (i)}
						<div
							class="h-10 w-2/3 animate-pulse rounded-xl bg-muted {i % 2 ? '' : 'ml-auto'}"
						></div>
					{/each}
				</div>
			{:else if store.loadError}
				<p class="text-center text-sm text-destructive">{store.loadError}</p>
			{:else if store.messages.length === 0}
				<p class="pt-6 text-center text-sm text-muted-foreground">
					Ask anything — this chat stays linked to what you're viewing.
				</p>
			{:else}
				<div class="space-y-3">
					{#each buildChatStream(store.messages, store.liveTools) as item (item.key)}
						{#if item.kind === 'message'}
							<MessageItem message={item.message} />
						{:else}
							<ToolCard view={toolViewFromLive(item.tool)} />
						{/if}
					{/each}
					{#if store.streamingThinking}
						<StreamingReasoning text={store.streamingThinking} />
					{/if}
					{#if store.agentThinking && !store.streamingThinking}
						<p class="text-xs text-muted-foreground">Thinking…</p>
					{/if}
				</div>
			{/if}
		</div>

		<div class="shrink-0 px-3 py-2.5">
			<Composer {store} />
		</div>
	{/if}
</CompanionFrame>
