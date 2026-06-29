<script lang="ts">
	import {
		AlertCircle,
		CircleCheck,
		CircleX,
		Download,
		Eye,
		FileArchive,
		FileDown,
		FileJson,
		FileText,
		FileX,
		Globe,
		Image as ImageIcon,
		PanelRight
	} from '@lucide/svelte';
	import type { CompanionSpec } from '$lib/ash/api';
	import type { ToolView } from '$lib/chat/events';
	import {
		fileDownloadData,
		serviceData,
		specializedToolType,
		writeDraftData
	} from '$lib/chat/tool-render';
	import ToolRichBody from './tool-rich-body.svelte';

	let {
		view,
		onOpen,
		conversationId
	}: {
		view: ToolView;
		/** Open a companion (View Draft / Preview / View in Pane). */
		onOpen?: (spec: CompanionSpec) => void;
		/** Needed to build the service-pane companion spec. */
		conversationId?: string;
	} = $props();

	const type = $derived(specializedToolType(view.toolName));
	const isRich = $derived(
		type === 'sub_agent' || type === 'await_sub_agents' || type === 'sandbox'
	);

	const hasInputs = $derived(!!view.inputs && Object.keys(view.inputs).length > 0);
	const hasOutput = $derived(
		view.output !== undefined && view.output !== null && view.output !== ''
	);
	const hasDetails = $derived(isRich || hasInputs || view.steps.length > 0 || hasOutput);

	// Default open while running; a failed sandbox auto-opens too (classic
	// open={!success}). Sticky once the user toggles.
	const defaultOpen = $derived(
		view.status === 'running' || (type === 'sandbox' && view.status === 'error')
	);
	let userOpen = $state<boolean | null>(null);
	const open = $derived(userOpen ?? defaultOpen);

	function toggle() {
		if (hasDetails) userOpen = !open;
	}

	function pretty(value: unknown): string {
		if (typeof value === 'string') return value;
		try {
			return JSON.stringify(value, null, 2);
		} catch {
			return String(value);
		}
	}

	const isPlainObject = (value: unknown): value is Record<string, unknown> =>
		!!value && typeof value === 'object' && !Array.isArray(value);
	const isPrimitive = (value: unknown): boolean =>
		value === null || ['string', 'number', 'boolean'].includes(typeof value);

	function fileIcon(mime: string | null) {
		if (mime === 'application/pdf') return FileText;
		if (mime?.startsWith('image/')) return ImageIcon;
		if (mime?.startsWith('text/')) return FileText;
		if (mime === 'application/zip') return FileArchive;
		if (mime === 'application/json') return FileJson;
		return FileDown;
	}

	// Auto-scroll the body to the bottom as step content streams in.
	let body = $state<HTMLDivElement | null>(null);
	const streamTick = $derived(view.steps.reduce((n, step) => n + step.content.length, 0));
	$effect(() => {
		void streamTick;
		if (open && view.status === 'running' && body) body.scrollTop = body.scrollHeight;
	});
</script>

<!-- Friendlier than raw JSON: a shallow object becomes a key/value list;
     nested values and non-objects fall back to formatted JSON. -->
{#snippet valueBlock(value: unknown)}
	{#if isPlainObject(value) && Object.keys(value).length > 0}
		<dl class="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1">
			{#each Object.entries(value) as [key, val] (key)}
				<dt class="font-mono text-muted-foreground">{key}</dt>
				<dd class="min-w-0">
					{#if isPrimitive(val)}
						<span class="break-words whitespace-pre-wrap">{val === null ? '—' : String(val)}</span>
					{:else}
						<pre
							class="overflow-x-auto rounded bg-secondary/60 px-2 py-1 font-mono text-[11px] whitespace-pre-wrap">{pretty(
								val
							)}</pre>
					{/if}
				</dd>
			{/each}
		</dl>
	{:else}
		<pre
			class="overflow-x-auto rounded bg-secondary/60 px-2 py-1 font-mono text-[11px] whitespace-pre-wrap">{pretty(
				value
			)}</pre>
	{/if}
{/snippet}

{#if type === 'service'}
	<!-- Sandbox service: compact card with a "View in Pane" action. -->
	{#if view.status === 'error'}
		<div
			class="ml-2 flex items-center gap-2 py-1 text-sm text-destructive/80"
			data-testid="tool-card"
		>
			<AlertCircle class="size-4 shrink-0" />
			<span>Service failed</span>
		</div>
	{:else}
		<div
			class="my-1 ml-2 max-w-lg rounded-lg bg-secondary/30 px-3 py-2.5"
			data-tool-status={view.status}
			data-testid="tool-card"
		>
			<div class="flex items-center gap-2 text-sm">
				<Globe class="size-4 shrink-0 text-success" />
				<span class="font-medium text-secondary-foreground">Service running</span>
			</div>
			{#if onOpen && conversationId}
				<button
					type="button"
					onclick={() => onOpen?.({ type: 'service', id: conversationId! })}
					class="wb-pill-btn mt-2 gap-1 text-xs"
				>
					<PanelRight class="size-3.5" /> View in Pane
				</button>
			{/if}
		</div>
	{/if}
{:else if type === 'file_download'}
	{@const file = fileDownloadData(view.output)}
	{@const FileIcon = fileIcon(file.mimeType)}
	{#if view.status === 'error' || file.error}
		<div
			class="ml-2 flex items-center gap-2 py-1 text-xs text-destructive/70"
			data-testid="tool-card"
		>
			<FileX class="size-3.5 shrink-0" />
			<span class="truncate">{file.error ?? 'File not found'}</span>
		</div>
	{:else}
		<div
			class="my-1 ml-2 max-w-lg rounded-lg bg-secondary/30 px-3 py-2.5"
			data-tool-status={view.status}
			data-testid="tool-card"
		>
			<div class="flex items-center gap-2 text-sm">
				<FileIcon class="size-4 shrink-0 text-primary" />
				<span class="min-w-0 truncate font-medium text-secondary-foreground">{file.filename}</span>
				{#if file.sizeText}
					<span class="shrink-0 text-xs text-muted-foreground">{file.sizeText}</span>
				{/if}
			</div>
			{#if file.downloadUrl}
				<div class="mt-2 flex items-center gap-2">
					<a
						href={file.downloadUrl}
						target="_blank"
						rel="noopener noreferrer"
						class="wb-pill-btn gap-1 text-xs"
					>
						<Download class="size-3.5" /> Download
					</a>
					{#if onOpen && file.mimeType === 'application/pdf'}
						<button
							type="button"
							onclick={() =>
								onOpen?.({
									type: 'pdf',
									id: file.fileId ?? '',
									name: file.filename,
									url: file.downloadUrl ?? undefined
								})}
							class="wb-pill-btn gap-1 text-xs"
						>
							<Eye class="size-3.5" /> Preview
						</button>
					{/if}
				</div>
			{/if}
		</div>
	{/if}
{:else if type === 'write_draft'}
	{@const draft = writeDraftData(view.output)}
	<div
		class="my-1 ml-2 max-w-lg rounded-lg bg-secondary/30 px-3 py-2.5"
		data-tool-status={view.status}
		data-testid="tool-card"
	>
		<div class="flex items-center gap-2 text-sm">
			<FileText class="size-4 shrink-0 text-primary" />
			<span class="min-w-0 truncate font-medium text-secondary-foreground">{draft.title}</span>
			<span
				class="shrink-0 rounded bg-secondary px-1.5 font-mono text-[11px] text-muted-foreground"
			>
				v{draft.version}
			</span>
			<span class="shrink-0 rounded border border-input px-1.5 text-[11px] text-muted-foreground">
				{draft.mode}
			</span>
		</div>
		{#if draft.lineCount}
			<p class="mt-1 text-xs text-muted-foreground">
				{draft.lineCount}
				{draft.lineCount === 1 ? 'line' : 'lines'}{#if draft.editedRange}
					(lines {draft.editedRange}){/if}
			</p>
		{/if}
		{#if onOpen && draft.draftId}
			<button
				type="button"
				onclick={() => onOpen?.({ type: 'draft', id: draft.draftId! })}
				class="wb-pill-btn mt-2 gap-1 text-xs"
			>
				<PanelRight class="size-3.5" /> View Draft
			</button>
		{/if}
	</div>
{:else}
	<!-- Generic + rich (sub_agent / await / sandbox) collapsible card. -->
	<div class="text-sm" data-tool-status={view.status} data-testid="tool-card">
		<button
			type="button"
			onclick={toggle}
			class="flex w-full items-center gap-2 py-0.5 text-left {hasDetails
				? 'cursor-pointer'
				: 'cursor-default'}"
			aria-expanded={hasDetails ? open : undefined}
		>
			{#if view.status === 'running'}
				<span
					class="size-3.5 shrink-0 animate-spin rounded-full border-2 border-muted-foreground border-t-transparent"
				></span>
			{:else if view.status === 'success'}
				<CircleCheck class="size-4 shrink-0 text-success" />
			{:else}
				<CircleX class="size-4 shrink-0 text-destructive" />
			{/if}

			<span class="shrink-0 font-medium text-secondary-foreground">{view.displayName}</span>

			{#if view.summary}
				<code
					class="min-w-0 truncate rounded bg-secondary px-2 py-0.5 font-mono text-xs text-muted-foreground"
				>
					{view.summary}
				</code>
			{/if}

			{#if view.durationMs !== null && view.durationMs > 0}
				<span class="shrink-0 text-[11px] text-muted-foreground">
					({(view.durationMs / 1000).toFixed(1)}s)
				</span>
			{/if}
		</button>

		{#if open && hasDetails}
			<div
				bind:this={body}
				class="ml-2 max-h-72 space-y-2 overflow-y-auto border-l border-input/60 pb-1 pl-3 text-xs"
				data-testid="tool-card-body"
			>
				{#if hasInputs && !isRich}
					<div>
						<p class="mb-0.5 font-medium text-muted-foreground">Inputs</p>
						{@render valueBlock(view.inputs)}
					</div>
				{/if}

				{#if view.steps.length > 0}
					<div class="space-y-1" data-testid="tool-steps">
						{#each view.steps as step (step.stepId)}
							<div class="flex flex-col gap-0.5">
								<div class="flex items-center gap-1.5">
									{#if step.status === 'running'}
										<span
											class="size-3 shrink-0 animate-spin rounded-full border-2 border-muted-foreground border-t-transparent"
										></span>
									{:else if step.status === 'success'}
										<CircleCheck class="size-3 shrink-0 text-success" />
									{:else}
										<CircleX class="size-3 shrink-0 text-destructive" />
									{/if}
									<span class="min-w-0 truncate text-secondary-foreground">{step.label}</span>
									{#if step.summary}
										<span class="min-w-0 truncate text-muted-foreground">— {step.summary}</span>
									{/if}
								</div>
								{#if step.content}
									<pre
										class="ml-[18px] overflow-x-auto rounded bg-secondary/40 px-2 py-1 font-mono text-[11px] whitespace-pre-wrap">{step.content}</pre>
								{/if}
							</div>
						{/each}
					</div>
				{/if}

				{#if isRich && type}
					<ToolRichBody {view} {type} />
				{:else if hasOutput}
					<div>
						<p class="mb-0.5 font-medium text-muted-foreground">Output</p>
						{@render valueBlock(view.output)}
					</div>
				{/if}
			</div>
		{/if}
	</div>
{/if}
