<script lang="ts">
	import { tick } from 'svelte';
	import { MessagesSquare } from '@lucide/svelte';
	import { conversationThreads, getConversation, messageHistory } from '$lib/ash/api';
	import { ConversationStore } from '$lib/chat/conversation-store.svelte';
	import Composer from '$lib/components/chat/composer.svelte';
	import MessageItem from '$lib/components/chat/message-item.svelte';
	import ToolCard from '$lib/components/chat/tool-card.svelte';
	import StreamingReasoning from '$lib/components/chat/streaming-reasoning.svelte';
	import { buildChatStream, toolViewFromLive } from '$lib/chat/events';
	import CompanionFrame from './companion-frame.svelte';

	let { threadId, onClose }: { threadId: string; onClose: () => void } = $props();

	let store = $state<ConversationStore | null>(null);
	let title = $state('Thread');
	let parentTitle = $state<string | null>(null);
	let sourceSnippet = $state<string | null>(null);
	let scroller = $state<HTMLElement | null>(null);
	let stickToBottom = $state(true);

	$effect(() => {
		const instance = new ConversationStore(threadId);
		store = instance;
		void instance.start();
		return () => instance.stop();
	});

	// Threads are conversations; the title carries the branch context, and
	// the parent + branched message feed the classic "Branched from" banner.
	$effect(() => {
		const id = threadId;
		parentTitle = null;
		sourceSnippet = null;
		void getConversation(id).then(async (result) => {
			if (id !== threadId || !result.success) return;
			if (result.data.title) title = result.data.title;

			const parentId = result.data.parentConversationId;
			if (!parentId) return;
			const parent = await getConversation(parentId);
			if (id === threadId && parent.success) {
				parentTitle = parent.data.title ?? 'conversation';
			}

			const threads = await conversationThreads(parentId);
			const branchedAtMessageId = threads.success
				? (threads.data.find((thread) => thread.id === id)?.branchedAtMessageId ?? null)
				: null;
			if (!branchedAtMessageId || id !== threadId) return;
			const history = await messageHistory(parentId);
			if (id !== threadId || !history.success) return;
			const source = history.data.find((message) => message.id === branchedAtMessageId);
			if (source) sourceSnippet = source.text.slice(0, 160);
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

<CompanionFrame {title} meta={parentTitle ? `Thread in ${parentTitle}` : null} {onClose}>
	{#snippet icon()}
		<MessagesSquare class="size-4 shrink-0 text-muted-foreground" />
	{/snippet}

	{#if sourceSnippet}
		<div
			class="shrink-0 border-b bg-secondary/40 px-4 py-2 text-xs text-muted-foreground"
			data-testid="thread-branch-banner"
		>
			<span class="font-medium text-secondary-foreground">Branched from:</span>
			<span class="ml-1">{sourceSnippet}</span>
		</div>
	{/if}

	{#if store}
		<div
			class="wb-scroll min-h-0 flex-1 overflow-y-auto px-4 py-3"
			bind:this={scroller}
			onscroll={onScroll}
			data-testid="thread-messages"
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
				<p class="pt-4 text-center text-sm text-muted-foreground">
					Start the thread — replies stay scoped to the branched message.
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
						<div class="flex items-center gap-2 px-1 py-2 text-sm text-muted-foreground">
							<span class="thinking-spinner text-primary" aria-hidden="true">◬</span>
							<span>Thinking…</span>
						</div>
					{/if}
				</div>
			{/if}
		</div>

		<div class="px-3 py-2.5">
			<Composer {store} />
		</div>
	{/if}
</CompanionFrame>
