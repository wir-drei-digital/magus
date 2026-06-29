<script lang="ts">
	import { onDestroy, tick } from 'svelte';
	import { ArrowDown, ChevronRight, MessagesSquare } from '@lucide/svelte';
	import {
		conversationThreads,
		createThread,
		filesForDisplay,
		type CompanionSpec,
		type DisplayAttachment,
		type ThreadSummary
	} from '$lib/ash/api';
	import { SvelteMap } from 'svelte/reactivity';
	import type { ConversationStore } from '$lib/chat/conversation-store.svelte';
	import { floorBoundaryMessageId, floorDividerLabel } from '$lib/chat/context-window';
	import { buildChatStream, toolViewFromLive } from '$lib/chat/events';
	import { readThreads, writeThreads } from '$lib/chat/threads-cache';
	import { workbench } from '$lib/stores/workbench.svelte';
	import NewResourceDialog from '$lib/components/shell/new-resource-dialog.svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';
	import Composer from './composer.svelte';
	import ConversationHeader from './conversation-header.svelte';
	import MessageItem from './message-item.svelte';
	import QueuedMessages from './queued-messages.svelte';
	import StreamingReasoning from './streaming-reasoning.svelte';
	import ToolCard from './tool-card.svelte';

	let {
		store,
		onCompanionRequest,
		highlightMessageId = null
	}: {
		store: ConversationStore;
		/** Opens a companion on this conversation's tab (wired by the page). */
		onCompanionRequest?: (spec: CompanionSpec) => void;
		/** Search deep-link target: scroll to + briefly flash this message. */
		highlightMessageId?: string | null;
	} = $props();

	const conversationId = $derived(store.conversationId);

	// Messages + in-flight tools as one time-ordered, de-duplicated render stream.
	const chatStream = $derived(buildChatStream(store.messages, store.liveTools));

	// Context-floor divider: marks the first in-window message when older
	// out-of-window messages are also loaded.
	const floorBoundaryId = $derived(
		floorBoundaryMessageId(store.messages, store.contextWindow?.windowStartAt ?? null)
	);
	const floorLabel = $derived(floorDividerLabel(store.contextWindow?.summaryMessageCount ?? 0));
	// A compaction left a summary to reveal: the divider becomes an expandable
	// toggle. Otherwise (rolling/cleared) it stays a plain, non-interactive line.
	const floorHasSummary = $derived(
		(store.contextWindow?.summaryMessageCount ?? 0) > 0 && !!store.contextWindow?.summary
	);
	let floorExpanded = $state(false);

	let scroller = $state<HTMLElement | null>(null);
	let stickToBottom = $state(true);

	// Attachment display maps, fetched in batches as messages reference them.
	const attachmentCache = new SvelteMap<string, DisplayAttachment>();
	const requestedAttachmentIds = new Set<string>();

	$effect(() => {
		const missing: string[] = [];
		for (const message of store.messages) {
			for (const id of message.attachments ?? []) {
				if (!requestedAttachmentIds.has(id)) {
					requestedAttachmentIds.add(id);
					missing.push(id);
				}
			}
		}
		if (missing.length === 0) return;
		void filesForDisplay(missing).then((result) => {
			if (!result.success) return;
			for (const file of result.data) attachmentCache.set(file.id, file);
		});
	});

	function openPdfAttachment(file: DisplayAttachment) {
		if (file.url) {
			onCompanionRequest?.({ type: 'pdf', id: file.id, name: file.name, url: file.url });
		}
	}

	// Threads branched off this conversation, keyed by their branch message.
	let threads = $state<ThreadSummary[]>([]);
	const threadsByMessage = $derived(
		new Map(
			threads
				.filter((thread) => thread.branchedAtMessageId !== null)
				.map((thread) => [thread.branchedAtMessageId as string, thread])
		)
	);

	$effect(() => {
		const id = conversationId;
		// Render instantly from cache on revisit; skip the refetch while the
		// cached list is still fresh (threads have no live channel, so a short
		// window is safe and local creation refreshes the entry below).
		const cached = readThreads(id);
		if (cached) threads = cached.threads;
		if (cached?.fresh) return;
		void conversationThreads(id).then((result) => {
			if (result.success) {
				threads = result.data;
				writeThreads(id, result.data);
			}
		});
	});

	// Auto-scroll on new content, but respect the user scrolling up.
	$effect(() => {
		void store.messages;
		void store.liveTools;
		void store.streamingThinking;
		if (stickToBottom) {
			void tick().then(() => scroller?.scrollTo({ top: scroller.scrollHeight }));
		}
	});

	// Search deep-link: once the target message is in the loaded set, scroll to
	// it and flash it briefly. Guarded so it fires once per highlight target and
	// doesn't fight the auto-scroll-to-bottom.
	let flashMessageId = $state<string | null>(null);
	let lastHighlighted: string | null = null;
	let flashTimer: ReturnType<typeof setTimeout> | null = null;

	$effect(() => {
		const target = highlightMessageId;
		if (!target || target === lastHighlighted) return;
		if (!store.messages.some((message) => message.id === target)) return;
		lastHighlighted = target;
		stickToBottom = false;
		void tick().then(() => {
			scroller
				?.querySelector(`[data-message-id="${target}"]`)
				?.scrollIntoView({ block: 'center', behavior: 'smooth' });
			flashMessageId = target;
			if (flashTimer) clearTimeout(flashTimer);
			flashTimer = setTimeout(() => (flashMessageId = null), 2500);
		});
	});

	onDestroy(() => {
		if (flashTimer) clearTimeout(flashTimer);
	});

	// Selecting text inside a message surfaces a floating "Ask chat" button that
	// drops the quoted selection into the composer (classic MessageTextSelection
	// parity). Scoped to this conversation's message list via [data-message-id].
	let askSelection = $state<{ text: string; x: number; y: number } | null>(null);

	function refreshAskSelection() {
		const selection = window.getSelection();
		if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
			askSelection = null;
			return;
		}
		const text = selection.toString().trim();
		const anchor = selection.anchorNode;
		const node = anchor instanceof Element ? anchor : anchor?.parentElement;
		const messageEl = node?.closest('[data-message-id]');
		if (!text || !messageEl || !scroller?.contains(messageEl)) {
			askSelection = null;
			return;
		}
		const rect = selection.getRangeAt(0).getBoundingClientRect();
		askSelection = { text, x: rect.left + rect.width / 2, y: rect.top };
	}

	function askAboutSelection() {
		if (!askSelection) return;
		store.requestInsertText(`> ${askSelection.text}\n\n`);
		window.getSelection()?.removeAllRanges();
		askSelection = null;
	}

	// px from the top at which scrolling up triggers the next older page. A
	// generous margin so loading kicks in before the user hits the very top.
	const LOAD_OLDER_MARGIN = 600;

	function onScroll() {
		if (!scroller) return;
		askSelection = null;
		stickToBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
		if (scroller.scrollTop < LOAD_OLDER_MARGIN) void loadOlder();
	}

	/**
	 * Fetches the next older page and pins the viewport in place across the
	 * prepend (the browser would otherwise keep scrollTop and visually jump).
	 * Auto-chains while still near the top so a short page or tall viewport
	 * keeps filling (classic auto-load parity).
	 */
	async function loadOlder() {
		if (!scroller || !store.hasMore || store.loadingOlder || store.loading) return;
		const prevHeight = scroller.scrollHeight;
		const prevTop = scroller.scrollTop;
		await store.loadOlder();
		await tick();
		if (!scroller) return;
		scroller.scrollTop = prevTop + (scroller.scrollHeight - prevHeight);
		if (store.hasMore && !store.loadingOlder && scroller.scrollTop < LOAD_OLDER_MARGIN) {
			void loadOlder();
		}
	}

	async function startThread(messageId: string) {
		// Reuse an existing thread for the message (classic does the same).
		const existing = threadsByMessage.get(messageId);
		if (existing) return onCompanionRequest?.({ type: 'thread', id: existing.id });

		const result = await createThread(conversationId, messageId);
		if (!result.success) return;

		threads = [...threads, result.data];
		writeThreads(conversationId, threads);
		void workbench.refreshThreads();
		onCompanionRequest?.({ type: 'thread', id: result.data.id });
	}

	function openThread(threadId: string) {
		onCompanionRequest?.({ type: 'thread', id: threadId });
	}

	// Classic "create prompt from message": the creation dialog, prefilled.
	let promptFromMessage = $state('');
	let promptDialogOpen = $state(false);

	function createPromptFrom(text: string) {
		promptFromMessage = text;
		promptDialogOpen = true;
	}

	// The degraded-connection banner waits out a grace period: every
	// conversation open passes through 'connecting' while the socket joins,
	// and that routine handshake must not flash a warning (the composer's
	// send button carries the quiet loading hint instead).
	const CONNECTION_GRACE_MS = 8_000;
	let showDegraded = $state(false);
	$effect(() => {
		if (store.connection === 'live') {
			showDegraded = false;
			return;
		}
		const timer = setTimeout(() => (showDegraded = true), CONNECTION_GRACE_MS);
		return () => clearTimeout(timer);
	});

	// Same idea for the history skeleton: snapshot-hydrated opens never show
	// it, and a sub-quarter-second fetch reads calmer as a brief blank than
	// as a flash of placeholder bubbles.
	let showSkeleton = $state(false);
	$effect(() => {
		if (!store.loading) {
			showSkeleton = false;
			return;
		}
		const timer = setTimeout(() => (showSkeleton = true), 250);
		return () => clearTimeout(timer);
	});
</script>

<svelte:document
	onmouseup={refreshAskSelection}
	onselectionchange={() => {
		const selection = window.getSelection();
		if (!selection || selection.isCollapsed) askSelection = null;
	}}
/>

{#if askSelection}
	<!-- mousedown (not click) + preventDefault so pressing the button doesn't
	     collapse the selection before the handler reads it. -->
	<button
		type="button"
		class="fixed z-40 flex -translate-x-1/2 -translate-y-full items-center gap-1 rounded-md bg-primary px-2 py-1 text-xs font-medium text-primary-foreground shadow-lg hover:bg-primary/90"
		style="left: {askSelection.x}px; top: {askSelection.y - 6}px"
		data-testid="message-ask-selection"
		onmousedown={(event) => {
			event.preventDefault();
			askAboutSelection();
		}}
	>
		<MessagesSquare class="size-3" /> Ask chat
	</button>
{/if}

<div class="flex h-full min-h-0 flex-col" data-testid="conversation-view">
	<ConversationHeader {store} {onCompanionRequest} />
	{#if showDegraded && store.connection !== 'live'}
		<div
			class="border-b bg-warning/10 px-4 py-1.5 text-center text-xs text-warning"
			role="status"
			data-testid="conversation-offline"
		>
			{store.connection === 'connecting' ? 'Reconnecting…' : 'Live updates unavailable'}
			— showing loaded history
		</div>
	{/if}

	{#if store.accessRevoked}
		<div
			class="border-b bg-destructive/10 px-4 py-1.5 text-center text-xs text-destructive"
			role="status"
		>
			Your access to this conversation was revoked.
		</div>
	{/if}

	<div
		class="relative min-h-0 flex-1 overflow-y-auto px-4 py-4"
		bind:this={scroller}
		onscroll={onScroll}
	>
		{#if store.loading && store.messages.length === 0}
			{#if showSkeleton}
				<div class="space-y-3">
					{#each [1, 2, 3] as i (i)}
						<div
							class="h-12 w-2/3 animate-pulse rounded-2xl bg-muted {i % 2 ? '' : 'ml-auto'}"
						></div>
					{/each}
				</div>
			{/if}
		{:else if store.loadError}
			<p class="text-center text-sm text-destructive">{store.loadError}</p>
		{:else if store.messages.length === 0}
			<p class="text-center text-sm text-muted-foreground">No messages yet.</p>
		{:else}
			<div class="mx-auto max-w-3xl space-y-3" data-testid="message-list">
				{#if store.hasMore}
					<div class="flex justify-center py-2" data-testid="load-older">
						{#if store.loadingOlder}
							<span
								class="size-4 animate-spin rounded-full border-2 border-current border-t-transparent text-muted-foreground"
							></span>
						{/if}
					</div>
				{/if}
				<!-- One time-ordered stream: messages and in-flight tools interleave
				     by timestamp, so a running tool never renders above a message it
				     didn't precede, and a tool's live card is de-duped the moment its
				     persisted event row lands. -->
				{#each chatStream as item (item.key)}
					{#if item.kind === 'message'}
						<div
							data-message-id={item.message.id}
							class="scroll-mt-4 rounded-xl transition-colors duration-700 {flashMessageId ===
							item.message.id
								? 'bg-primary/10 ring-2 ring-primary/30'
								: ''}"
						>
							<MessageItem
								message={item.message}
								thread={threadsByMessage.get(item.message.id) ?? null}
								onStartThread={onCompanionRequest ? (id) => void startThread(id) : undefined}
								onOpenThread={onCompanionRequest ? openThread : undefined}
								attachmentFor={(id) => attachmentCache.get(id) ?? null}
								onOpenPdf={onCompanionRequest ? openPdfAttachment : undefined}
								onToggleDisabled={(id) => void store.toggleDisabled(id)}
								onRetry={(text) => void store.send(text)}
								onCreatePrompt={createPromptFrom}
								onOpenCompanion={onCompanionRequest}
								conversationId={store.conversationId}
							/>
						</div>
					{:else}
						<ToolCard
							view={toolViewFromLive(item.tool)}
							onOpen={onCompanionRequest}
							conversationId={store.conversationId}
						/>
					{/if}
					<!-- Context-floor divider, rendered just BELOW its boundary message
					     (the last out-of-window message). It marks where the dropped/
					     summarized history ends and the live window begins, and surfaces
					     immediately after a Clear even before any new message arrives. -->
					{#if item.kind === 'message' && item.message.id === floorBoundaryId}
						{#if floorHasSummary}
							<div class="py-1" data-testid="context-floor-divider">
								<button
									type="button"
									class="flex w-full items-center gap-3 text-muted-foreground transition-colors hover:text-foreground"
									onclick={() => (floorExpanded = !floorExpanded)}
									aria-expanded={floorExpanded}
									data-testid="context-floor-toggle"
								>
									<div class="h-px flex-1 bg-border"></div>
									<span class="flex items-center gap-1 text-[11px]">
										<ChevronRight
											class="size-3 transition-transform {floorExpanded ? 'rotate-90' : ''}"
										/>
										{floorLabel}
									</span>
									<div class="h-px flex-1 bg-border"></div>
								</button>
								{#if floorExpanded}
									<div
										class="mx-auto mt-2 max-w-prose whitespace-pre-wrap rounded-md bg-muted/60 px-3 py-2 text-[11px] leading-relaxed text-muted-foreground"
										data-testid="context-floor-summary"
									>
										{store.contextWindow?.summary}
									</div>
								{/if}
							</div>
						{:else}
							<div class="flex items-center gap-3 py-1" data-testid="context-floor-divider">
								<div class="h-px flex-1 bg-border"></div>
								<span class="text-[11px] text-muted-foreground">{floorLabel}</span>
								<div class="h-px flex-1 bg-border"></div>
							</div>
						{/if}
					{/if}
				{/each}

				{#if store.streamingThinking}
					<StreamingReasoning text={store.streamingThinking} />
				{/if}

				{#if !store.streamingThinking && store.compactionInProgress}
					<div
						class="flex items-center gap-2 px-1 py-1 text-sm text-muted-foreground"
						role="status"
						data-testid="agent-compacting"
					>
						<span
							class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent text-primary"
							aria-hidden="true"
						></span>
						<span>Compacting context…</span>
					</div>
				{/if}

				{#if store.agentThinking && !store.streamingThinking && !store.compactionInProgress}
					<div class="flex flex-col items-start gap-1" role="status" data-testid="agent-thinking">
						{#if store.agentDelayed}
							<p class="px-1 text-[11px] text-muted-foreground" data-testid="agent-delayed">
								Taking longer than usual…
							</p>
						{/if}
						<div class="flex items-center gap-2 px-1 py-1 text-sm text-muted-foreground">
							<span class="thinking-spinner text-primary" aria-hidden="true">◬</span>
							<span>Thinking…</span>
						</div>
					</div>
				{/if}
			</div>
		{/if}
	</div>

	{#if !stickToBottom}
		<div class="pointer-events-none relative">
			<button
				type="button"
				class="pointer-events-auto absolute -top-12 right-6 flex size-9 items-center justify-center rounded-full border border-input bg-background text-muted-foreground shadow-md transition-colors hover:text-foreground"
				aria-label="Scroll to bottom"
				data-testid="scroll-to-bottom"
				onclick={() => {
					stickToBottom = true;
					scroller?.scrollTo({ top: scroller.scrollHeight, behavior: 'smooth' });
				}}
			>
				<ArrowDown class="size-4" />
			</button>
		</div>
	{/if}

	<div class="px-4 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]">
		{#if store.typing.length > 0}
			<p class="pb-1 text-xs text-muted-foreground">
				{store.typing.map((entry) => entry.userName).join(', ')} typing…
			</p>
		{/if}
		<QueuedMessages
			messages={store.queued}
			onSendNow={() => void store.sendNow()}
			onRemove={(id) => void store.removeQueued(id)}
		/>
		<Composer {store} />
	</div>
</div>

<NewResourceDialog kind="prompt" bind:open={promptDialogOpen} initialBody={promptFromMessage} />

<!-- Classic LimitExceededModal: plan-limit denials get a dialog with the
     upgrade path, not just an inline error row. -->
<Dialog.Root
	open={store.limitExceeded !== null}
	onOpenChange={(value) => {
		if (!value) store.limitExceeded = null;
	}}
>
	<Dialog.Content class="sm:max-w-md" data-testid="limit-exceeded-dialog">
		<Dialog.Header>
			<Dialog.Title>Plan limit reached</Dialog.Title>
			<Dialog.Description>{store.limitExceeded}</Dialog.Description>
		</Dialog.Header>
		<Dialog.Footer>
			<Button variant="ghost" onclick={() => (store.limitExceeded = null)}>Dismiss</Button>
			<Button
				onclick={() => {
					store.limitExceeded = null;
					window.location.href = '/settings/subscription';
				}}
			>
				Manage subscription
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
