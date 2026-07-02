<script lang="ts">
	import { onDestroy } from 'svelte';
	import {
		AlertCircle,
		AlertTriangle,
		Box,
		Brain,
		Check,
		ClipboardCopy,
		Download,
		Eye,
		EyeOff,
		File,
		FilePen,
		FileText,
		Film,
		Globe,
		Image,
		Info,
		MessagesSquare,
		PlayCircle,
		Quote,
		RefreshCw,
		ScanSearch,
		Search,
		Sparkles,
		Zap,
		ZapOff
	} from '@lucide/svelte';
	import type { ChatMessage, CompanionSpec, DisplayAttachment } from '$lib/ash/api';
	import { isBrokenSelection } from '$lib/chat/broken-selection';
	import { toolViewFromPersisted } from '$lib/chat/events';
	import { eventVisual } from '$lib/chat/event-style';
	import {
		draftEventLabel,
		jobTriggerInfo,
		selectionIndicators,
		wakeupInfo,
		type SelectionIcon
	} from '$lib/chat/message-meta';
	import { referencedCitations } from '$lib/chat/markdown';
	import { formatFileSize } from '$lib/files/format';
	import { messageTime } from '$lib/time';
	import Markdown from './markdown.svelte';
	import ToolCard from './tool-card.svelte';

	let {
		message,
		thread = null,
		onStartThread,
		onOpenThread,
		attachmentFor,
		onOpenPdf,
		onToggleDisabled,
		onRetry,
		onResetBrokenSelection,
		onCreatePrompt,
		onOpenCompanion,
		conversationId
	}: {
		message: ChatMessage;
		/** Existing thread branched at this message, if any. */
		thread?: { id: string; messageCount?: number } | null;
		onStartThread?: (messageId: string) => void;
		onOpenThread?: (threadId: string) => void;
		/** Resolves an attachment id to its display map (null while loading). */
		attachmentFor?: (id: string) => DisplayAttachment | null;
		onOpenPdf?: (attachment: DisplayAttachment) => void;
		/** Classic eye toggle: exclude/include the message in the LLM context. */
		onToggleDisabled?: (id: string) => void;
		/** Re-sends this message's text (user messages only). */
		onRetry?: (text: string) => void;
		/** Resets the scoped model selection and retries the blocked message
		 *  behind a broken-selection event (event messages only). */
		onResetBrokenSelection?: (messageId: string) => void;
		/** Opens the prompt creation dialog prefilled with this text. */
		onCreatePrompt?: (text: string) => void;
		/** Opens a companion from a tool card's action button (View Draft, etc.). */
		onOpenCompanion?: (spec: CompanionSpec) => void;
		/** The conversation id, for the service-pane companion spec. */
		conversationId?: string;
	} = $props();

	const resolvedAttachments = $derived(
		attachmentFor
			? (message.attachments ?? [])
					.map((id) => attachmentFor(id))
					.filter((file): file is DisplayAttachment => file !== null)
			: []
	);

	const ATTACHMENT_ICONS: Record<string, typeof File> = {
		image: Image,
		video: Film
	};

	const isUser = $derived(message.source === 'user');
	const isEvent = $derived(message.messageType !== 'message');
	const toolData = $derived(message.toolCallData);
	// A degraded-model hard-stop event (Task 1): its tool_call_data is the
	// broken_model_selection payload, not a tool result; render remediation.
	const brokenSelection = $derived(isEvent && isBrokenSelection(toolData));
	const canBranch = $derived(
		message.status === 'complete' && (onStartThread !== undefined || thread !== null)
	);

	function branch() {
		if (thread) onOpenThread?.(thread.id);
		else onStartThread?.(message.id);
	}

	let copied = $state(false);
	let copiedTimer: ReturnType<typeof setTimeout> | null = null;

	async function copyText() {
		try {
			await navigator.clipboard.writeText(message.text);
			copied = true;
			if (copiedTimer) clearTimeout(copiedTimer);
			copiedTimer = setTimeout(() => (copied = false), 1500);
		} catch {
			// Clipboard permission denied — nothing useful to surface.
		}
	}

	onDestroy(() => {
		if (copiedTimer) clearTimeout(copiedTimer);
	});

	const settled = $derived(message.status === 'complete' || message.status === 'error');

	// Only the citations the model actually referenced via [N] (falls back to
	// all when none were referenced) — parity with get_referenced_citations.
	const sources = $derived(referencedCitations(message.text, message.citations));

	// Typed system-event styling (ported from events.ex detect_event_style).
	const eventVis = $derived(eventVisual(message.text));
	const EVENT_ICON = {
		warning: AlertTriangle,
		error: AlertCircle,
		search: Search,
		note: FileText,
		dice: Box,
		info: Info
	} as const;
	const EVENT_COLOR = {
		warning: 'text-warning',
		error: 'text-destructive',
		info: 'text-muted-foreground'
	} as const;

	// Pinned-context chips on user messages (selection_indicators parity).
	const SELECTION_ICON: Record<SelectionIcon, typeof FilePen> = {
		draft: FilePen,
		pdf: FileText,
		service: Globe,
		quote: Quote,
		brain: Brain
	};
	const selections = $derived(isUser ? selectionIndicators(message.metadata) : []);

	// Wake-up trace styling (heartbeat / manual_trigger) by stage.
	const wakeup = $derived(isEvent ? wakeupInfo(message.metadata) : null);
	const WAKEUP_STYLE = {
		complete: { icon: Zap, color: 'text-success' },
		skipped: { icon: ZapOff, color: 'text-muted-foreground/50' },
		failed: { icon: Zap, color: 'text-destructive' },
		running: { icon: Zap, color: 'text-info' }
	} as const;
	const wakeupStyle = $derived(
		wakeup
			? (WAKEUP_STYLE[wakeup.stage as keyof typeof WAKEUP_STYLE] ?? WAKEUP_STYLE.running)
			: null
	);

	// Persisted reasoning: joined text + a short preview for the summary line.
	const reasoningText = $derived((message.reasoningSummary ?? []).join('\n\n'));
	const reasoningPreview = $derived.by(() => {
		const flat = reasoningText.slice(0, 60).replace(/\n/g, ' ');
		return reasoningText.length > 60 ? `${flat}…` : flat;
	});
</script>

{#snippet threadAction()}
	{#if canBranch}
		<button
			type="button"
			class="flex shrink-0 items-center gap-0.5 rounded-md px-1.5 py-1 text-xs transition-colors {thread
				? 'text-primary'
				: 'text-muted-foreground hover:bg-accent hover:text-foreground'}"
			data-testid={thread ? 'message-open-thread' : 'message-start-thread'}
			aria-label={thread ? 'Open thread' : 'Start thread'}
			title={thread ? 'Open thread' : 'Start thread'}
			onclick={branch}
		>
			<MessagesSquare class="size-3.5" />
			{#if thread?.messageCount}
				<span class="text-[10px]" data-testid="thread-reply-count">{thread.messageCount}</span>
			{/if}
		</button>
	{/if}
{/snippet}

<!-- Classic message footer: hover-revealed action strip below the bubble.
     The eye toggle stays visible while a message is hidden from context. -->
{#snippet footerActions()}
	<div
		class="flex items-center gap-0.5 transition-opacity {message.disabled
			? 'opacity-100'
			: 'opacity-0 group-hover:opacity-100'}"
		data-testid="message-actions"
	>
		{#if onToggleDisabled && settled}
			<button
				type="button"
				class="rounded-md px-1.5 py-1 transition-colors hover:bg-accent {message.disabled
					? 'text-warning'
					: 'text-muted-foreground hover:text-foreground'}"
				title={message.disabled ? 'Include message in context' : 'Hide message from context'}
				data-testid="message-toggle-disabled"
				onclick={() => onToggleDisabled(message.id)}
			>
				{#if message.disabled}<Eye class="size-3.5" />{:else}<EyeOff class="size-3.5" />{/if}
			</button>
		{/if}
		{#if onRetry && isUser && settled}
			<button
				type="button"
				class="rounded-md px-1.5 py-1 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
				title="Retry message"
				data-testid="message-retry"
				onclick={() => onRetry(message.text)}
			>
				<RefreshCw class="size-3.5" />
			</button>
		{/if}
		{#if message.text.trim() !== ''}
			<button
				type="button"
				class="rounded-md px-1.5 py-1 transition-colors hover:bg-accent {copied
					? 'text-success'
					: 'text-muted-foreground hover:text-foreground'}"
				title="Copy to clipboard"
				data-testid="message-copy"
				onclick={() => void copyText()}
			>
				{#if copied}<Check class="size-3.5" />{:else}<ClipboardCopy class="size-3.5" />{/if}
			</button>
		{/if}
		{#if onCreatePrompt && settled && message.text.trim() !== ''}
			<button
				type="button"
				class="rounded-md px-1.5 py-1 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
				title="Create prompt from message"
				data-testid="message-create-prompt"
				onclick={() => onCreatePrompt(message.text)}
			>
				<Sparkles class="size-3.5" />
			</button>
		{/if}
		{@render threadAction()}
	</div>
{/snippet}

{#snippet selectionChips()}
	{#if selections.length > 0}
		<div class="mb-2 flex flex-wrap gap-1" data-testid="selection-indicators">
			{#each selections as ind, index (index)}
				{@const SelIcon = SELECTION_ICON[ind.icon]}
				<div
					class="flex max-w-full items-center gap-1.5 rounded bg-foreground/5 px-2 py-0.5 text-xs text-foreground/80"
				>
					<SelIcon class="size-3 shrink-0" />
					{#if ind.label}<span class="text-muted-foreground">{ind.label}</span>{/if}
					<span class="truncate">{ind.text}</span>
				</div>
			{/each}
		</div>
	{/if}
{/snippet}

{#snippet attachmentChips()}
	{#if resolvedAttachments.length > 0}
		<div class="mb-2 flex flex-wrap gap-2" data-testid="message-attachments">
			{#each resolvedAttachments as file (file.id)}
				{#if file.type === 'image' && file.url}
					<div class="group relative inline-block">
						<a href={file.url} target="_blank" rel="noopener noreferrer">
							<img
								src={file.url}
								alt={file.name}
								class="max-h-48 rounded-lg border border-input object-cover"
							/>
						</a>
						<a
							href={file.url}
							download
							class="absolute top-2 right-2 rounded-full bg-background/80 p-1.5 text-foreground opacity-0 shadow transition-opacity group-hover:opacity-100"
							title="Download image"
							data-testid="download-image"
						>
							<Download class="size-4" />
						</a>
					</div>
				{:else if file.type === 'video' && file.url}
					<div class="group relative">
						<!-- svelte-ignore a11y_media_has_caption -->
						<video
							controls
							preload="metadata"
							class="max-h-72 max-w-lg rounded-lg border border-input"
						>
							<source src={file.url} type={file.mimeType ?? undefined} />
						</video>
						<a
							href={file.url}
							download
							class="absolute top-2 right-2 rounded-full bg-background/80 p-1.5 text-foreground opacity-0 shadow transition-opacity group-hover:opacity-100"
							title="Download video"
							data-testid="download-video"
						>
							<Download class="size-4" />
						</a>
					</div>
				{:else}
					{@const Icon = ATTACHMENT_ICONS[file.type] ?? File}
					<span class="flex items-center gap-1">
						<a
							href={file.url}
							target="_blank"
							rel="noopener noreferrer"
							class="flex max-w-60 items-center gap-2 rounded-lg border border-input bg-secondary px-2.5 py-1.5 text-secondary-foreground transition-colors hover:bg-accent/60"
						>
							<Icon class="size-4 shrink-0 text-muted-foreground" />
							<span class="min-w-0">
								<span class="block truncate text-xs font-medium">{file.name}</span>
								{#if file.size}
									<span class="block text-[10px] text-muted-foreground">
										{formatFileSize(file.size)}
									</span>
								{/if}
							</span>
						</a>
						{#if onOpenPdf && file.mimeType === 'application/pdf'}
							<button
								type="button"
								class="rounded p-1 text-primary hover:bg-accent"
								title="View in PDF viewer"
								data-testid="open-pdf-attachment"
								onclick={() => onOpenPdf(file)}
							>
								<Eye class="size-3.5" />
							</button>
						{/if}
					</span>
				{/if}
			{/each}
		</div>
	{/if}
{/snippet}

{#if isEvent}
	{#if brokenSelection}
		<!-- Degraded-model hard-stop (Task 1): the message text explains the
		     failure; the action clears the scoped selection and retries. -->
		<div class="flex flex-col gap-1.5 py-0.5" data-role="event" data-event="broken_selection">
			<div class="flex items-center gap-2 text-sm">
				<AlertTriangle class="size-4 shrink-0 text-warning" />
				<span class="text-muted-foreground">{message.text}</span>
			</div>
			{#if onResetBrokenSelection}
				<button
					type="button"
					class="ml-6 self-start rounded-md border border-input px-2 py-1 text-xs text-foreground transition-colors hover:bg-accent"
					data-testid="broken-selection-reset"
					onclick={() => onResetBrokenSelection(message.id)}
				>
					<RefreshCw class="mr-1 inline size-3.5" />
					Reset to default and retry
				</button>
			{/if}
		</div>
	{:else if toolData}
		<!-- Persisted tool event: same collapsible card as the live tool, so it
		     settles into its persisted twin without a visual jump. -->
		<div data-role="event">
			<ToolCard view={toolViewFromPersisted(toolData)} onOpen={onOpenCompanion} {conversationId} />
		</div>
	{:else if message.messageType === 'job_trigger'}
		<!-- Scheduled-job trigger trace: name + collapsible prompt. -->
		{@const job = jobTriggerInfo(message.metadata)}
		<details class="group ml-0.5" data-role="event" data-event="job_trigger">
			<summary
				class="flex cursor-pointer list-none items-center gap-2 text-sm text-muted-foreground select-none hover:text-foreground/70 [&::-webkit-details-marker]:hidden"
			>
				<PlayCircle class="size-4 shrink-0 text-info" />
				<span class="font-medium text-foreground/80">{job.jobName}</span>
				{#if job.memoryName}<span class="truncate text-xs">({job.memoryName})</span>{/if}
			</summary>
			<div
				class="mt-1.5 ml-2 border-l border-input pl-3 text-sm whitespace-pre-wrap text-muted-foreground"
			>
				{message.text}
			</div>
		</details>
	{:else if message.messageType === 'draft_event'}
		<!-- Draft review/export trace: labeled, collapsible. -->
		{@const label = draftEventLabel(message.metadata)}
		<details class="group ml-0.5" data-role="event" data-event="draft_event">
			<summary
				class="flex cursor-pointer list-none items-center gap-2 text-sm text-muted-foreground select-none hover:text-foreground/70 [&::-webkit-details-marker]:hidden"
			>
				<ScanSearch class="size-4 shrink-0 text-success" />
				<span>{label}</span>
			</summary>
			<div
				class="mt-1.5 ml-2 border-l border-input pl-3 text-sm whitespace-pre-wrap text-muted-foreground"
			>
				{message.text}
			</div>
		</details>
	{:else if wakeup && wakeupStyle}
		<!-- Wake-up trace (heartbeat / manual_trigger): zap + stage color. -->
		{@const WakeIcon = wakeupStyle.icon}
		<div
			class="flex items-center gap-2 py-0.5 text-xs italic"
			data-role="event"
			data-event="wakeup"
			data-wakeup-stage={wakeup.stage}
		>
			<WakeIcon class="size-3.5 shrink-0 {wakeupStyle.color}" />
			<span class="text-muted-foreground/70">{message.text}</span>
		</div>
	{:else}
		<!-- System event row: icon + color by detected severity. -->
		{@const EventIcon = EVENT_ICON[eventVis.icon]}
		<div
			class="flex items-center gap-2 py-0.5 text-sm"
			data-role="event"
			data-event-severity={eventVis.severity}
		>
			<EventIcon class="size-4 shrink-0 {EVENT_COLOR[eventVis.severity]}" />
			<span class="text-muted-foreground">{message.text}</span>
		</div>
	{/if}
{:else if isUser}
	<div class="group flex flex-col items-end gap-0.5" data-role="user">
		<div
			class="max-w-[75%] rounded-xl border border-border bg-user-bubble px-4 py-2.5 text-foreground {message.status ===
				'pending' || message.disabled
				? 'opacity-60'
				: ''}"
		>
			{@render selectionChips()}
			{@render attachmentChips()}
			<p class="text-sm whitespace-pre-wrap">{message.text}</p>
			<p class="mt-1.5 text-[11px] text-muted-foreground">
				{messageTime(message.insertedAt)}
			</p>
		</div>
		{@render footerActions()}
	</div>
{:else}
	<!-- Agent message: subtle card with model + time attribution inside. -->
	<div class="group flex flex-col items-start gap-0.5" data-role="agent">
		<div
			class="max-w-[92%] rounded-xl border border-input bg-card/80 px-4 py-3 {message.disabled
				? 'opacity-60'
				: ''}"
		>
			{@render attachmentChips()}
			{#if message.reasoningSummary && message.reasoningSummary.length > 0}
				<details class="group mb-2" data-testid="message-reasoning">
					<summary
						class="flex cursor-pointer list-none items-center gap-2 text-sm text-muted-foreground select-none hover:text-foreground/70 [&::-webkit-details-marker]:hidden"
					>
						<Brain class="size-4 shrink-0 group-hover:text-warning" />
						<span>Reasoning</span>
						<span
							class="max-w-md truncate rounded bg-foreground/5 px-2 py-0.5 font-mono text-xs text-muted-foreground/70"
						>
							{reasoningPreview}
						</span>
					</summary>
					<div class="mt-2 ml-2 max-h-64 overflow-y-auto border-l border-input pl-3 text-xs">
						<Markdown text={reasoningText} />
					</div>
				</details>
			{/if}
			<Markdown
				text={message.text}
				citations={message.citations}
				streaming={message.status === 'streaming'}
			/>
			{#if message.status === 'streaming'}
				<span class="mt-1 inline-block size-2 animate-pulse rounded-full bg-foreground/40"></span>
			{:else if message.status === 'error'}
				<p class="mt-1 text-xs text-destructive">This response failed.</p>
			{/if}
			{#if sources.length > 0}
				<div class="mt-3 border-t border-input pt-3" data-testid="message-citations">
					<p class="mb-1.5 text-xs text-muted-foreground">Sources:</p>
					<ul class="space-y-1 text-sm">
						{#each sources as citation, index (index)}
							{#if typeof citation['url'] === 'string'}
								<li class="truncate">
									<a
										href={citation['url']}
										target="_blank"
										rel="noopener noreferrer"
										class="text-primary underline-offset-2 hover:underline"
									>
										{typeof citation['title'] === 'string' && citation['title']
											? citation['title']
											: citation['url']}
									</a>
								</li>
							{/if}
						{/each}
					</ul>
				</div>
			{/if}
			<p class="mt-2 text-[11px] text-muted-foreground">
				{message.modelName ? `${message.modelName} · ` : ''}{messageTime(message.insertedAt)}
			</p>
		</div>
		{@render footerActions()}
	</div>
{/if}
