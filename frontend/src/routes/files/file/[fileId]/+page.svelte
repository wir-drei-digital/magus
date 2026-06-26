<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { ArrowLeft, Download, MessageSquare, Trash2 } from '@lucide/svelte';
	import { fileDownloadUrl, fileUrl, getFile, trashFile, type FileEntry } from '$lib/ash/api';
	import { openCompanionChat } from '$lib/ash/api';
	// Lazy: keeps the chat view stack out of the files route chunk.
	const loadConversationCompanion = () =>
		import('$lib/components/companions/conversation-companion.svelte');
	import * as Resizable from '$lib/components/ui/resizable';
	import { formatFileSize } from '$lib/files/format';
	import { relativeTime } from '$lib/time';
	import { workbench } from '$lib/stores/workbench.svelte';

	const fileId = $derived(page.params.fileId!);

	let file = $state<FileEntry | null>(null);
	let textContent = $state<string | null>(null);
	let loadError = $state<string | null>(null);

	// One-shot: deep links sync the nav once; afterwards the mode strip
	// may switch the nav freely without this route forcing it back.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'files') void workbench.setMode('files');
	});

	$effect(() => {
		const id = fileId;
		file = null;
		textContent = null;
		chatConversationId = null;
		loadError = null;

		void getFile(id).then(async (result) => {
			if (id !== fileId) return;
			if (!result.success) {
				loadError = result.errors[0]?.message ?? 'File could not be loaded';
				return;
			}
			file = result.data;

			// Small text files render inline; everything else uses native viewers.
			if (result.data.type === 'text' && result.data.fileSize < 512 * 1024) {
				try {
					const response = await fetch(fileUrl(result.data));
					if (response.ok && id === fileId) textContent = await response.text();
				} catch {
					// Falls through to the download card.
				}
			}
		});
	});

	const isPdf = $derived(file?.mimeType === 'application/pdf');

	let openingChat = $state(false);
	/** Chat docked beside the file (classic: file primary, chat companion). */
	let chatConversationId = $state<string | null>(null);

	async function toggleChat() {
		if (!file || openingChat) return;
		if (chatConversationId) {
			chatConversationId = null;
			return;
		}
		openingChat = true;
		const result = await openCompanionChat('file', file.id);
		if (result.success) chatConversationId = result.data.conversationId;
		openingChat = false;
	}

	async function trash() {
		if (!file) return;
		const result = await trashFile(file.id);
		if (result.success) await goto(`${base}/files`);
	}
</script>

<svelte:head>
	<title>Magus — {file?.name ?? 'File'}</title>
</svelte:head>

<Resizable.PaneGroup direction="horizontal" autoSaveId="magus:file-chat-split">
	<Resizable.Pane defaultSize={60} minSize={35}>
		<div class="flex h-full min-h-0 flex-col" data-testid="file-detail">
			<header class="flex shrink-0 items-center gap-3 border-b py-2.5 pr-4 pl-14 md:pl-4">
				<a
					href="{base}/files{file?.folderId ? `/folder/${file.folderId}` : ''}"
					class="shrink-0 rounded-md p-1 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
					aria-label="Back to files"
				>
					<ArrowLeft class="size-4" />
				</a>
				<div class="min-w-0 flex-1">
					<h1 class="truncate text-sm font-semibold" data-testid="file-detail-name">
						{file?.name ?? '…'}
					</h1>
					{#if file}
						<p class="text-xs text-muted-foreground">
							{formatFileSize(file.fileSize)} · {file.mimeType} · updated {relativeTime(
								file.updatedAt
							)}
						</p>
					{/if}
				</div>
				{#if file}
					<button
						type="button"
						class="wb-pill-btn shrink-0 {chatConversationId ? 'wb-pill-btn-active' : ''}"
						data-testid="file-open-chat"
						disabled={openingChat}
						onclick={() => void toggleChat()}
					>
						<MessageSquare class="size-3.5" />
						<span>{chatConversationId ? 'Close chat' : 'Open chat'}</span>
					</button>
					<a
						href={fileDownloadUrl(file)}
						target="_blank"
						rel="noopener noreferrer"
						class="wb-pill-btn shrink-0"
						data-testid="file-detail-download"
					>
						<Download class="size-3.5" />
						<span>Download</span>
					</a>
					<button
						type="button"
						class="wb-pill-btn wb-pill-btn-square shrink-0"
						aria-label="Move to trash"
						onclick={() => void trash()}
					>
						<Trash2 class="size-3.5" />
					</button>
				{/if}
			</header>

			<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
				{#if loadError}
					<p class="p-6 text-sm text-destructive">{loadError}</p>
				{:else if !file}
					<div class="space-y-3 p-6">
						<div class="h-5 w-1/3 animate-pulse rounded bg-muted"></div>
						<div class="h-64 animate-pulse rounded-xl bg-muted"></div>
					</div>
				{:else if file.type === 'image'}
					<div class="flex h-full items-center justify-center p-6">
						<img src={fileUrl(file)} alt={file.name} class="max-h-full max-w-full rounded-lg" />
					</div>
				{:else if isPdf}
					<iframe src={fileUrl(file)} title={file.name} class="h-full w-full border-0"></iframe>
				{:else if file.type === 'video'}
					<div class="flex h-full items-center justify-center p-6">
						<!-- svelte-ignore a11y_media_has_caption — user uploads carry no track -->
						<video src={fileUrl(file)} controls class="max-h-full max-w-full rounded-lg"></video>
					</div>
				{:else if textContent !== null}
					<pre class="whitespace-pre-wrap p-6 font-mono text-sm leading-relaxed">{textContent}</pre>
				{:else}
					<div class="flex h-full flex-col items-center justify-center gap-3 p-6">
						<p class="text-sm text-muted-foreground">No inline preview for this file type.</p>
						<a
							href={fileDownloadUrl(file)}
							target="_blank"
							rel="noopener noreferrer"
							class="text-sm font-medium text-primary underline-offset-2 hover:underline"
						>
							Download {file.name}
						</a>
					</div>
				{/if}
			</div>
		</div>
	</Resizable.Pane>
	{#if chatConversationId}
		<Resizable.Handle />
		<Resizable.Pane defaultSize={40} minSize={25}>
			{#await loadConversationCompanion() then { default: ConversationCompanion }}
				<ConversationCompanion
					conversationId={chatConversationId}
					onClose={() => (chatConversationId = null)}
				/>
			{/await}
		</Resizable.Pane>
	{/if}
</Resizable.PaneGroup>
