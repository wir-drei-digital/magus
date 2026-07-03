<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { ArrowLeft, Download, MessageSquare, Trash2, ZoomIn, ZoomOut } from '@lucide/svelte';
	import { fileDownloadUrl, fileUrl, getFile, trashFile, type FileEntry } from '$lib/ash/api';
	import { openCompanionChat } from '$lib/ash/api';
	import type { ComposerSelection } from '$lib/chat/conversation-store.svelte';
	// Lazy: keeps the chat view stack out of the files route chunk.
	const loadConversationCompanion = () =>
		import('$lib/components/companions/conversation-companion.svelte');
	import PdfViewer from '$lib/components/files/pdf-viewer.svelte';
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

	async function openChat(): Promise<boolean> {
		if (!file) return false;
		if (chatConversationId) return true;
		if (openingChat) return false;
		openingChat = true;
		const result = await openCompanionChat('file', file.id);
		if (result.success) chatConversationId = result.data.conversationId;
		openingChat = false;
		return result.success;
	}

	async function toggleChat() {
		if (chatConversationId) {
			chatConversationId = null;
			return;
		}
		await openChat();
	}

	// Classic PdfPaneComponent zoom steps; 100 = 1 PDF point per CSS pixel.
	const ZOOM_STEPS = [25, 50, 75, 100, 125, 150, 200, 300];
	let zoom = $state(100);
	function zoomBy(direction: 1 | -1) {
		const index = ZOOM_STEPS.indexOf(zoom);
		const next = ZOOM_STEPS[index + direction];
		if (next) zoom = next;
	}

	/**
	 * PDF region capture → docked chat composer pill. Opens the file's
	 * companion chat first when it isn't docked yet (classic file_view
	 * pdf:ask_about_selection parity).
	 */
	let companionSelection = $state<{ selection: ComposerSelection; revision: number } | null>(null);

	async function onPdfSelection(capture: { image: string; text: string; page: number }) {
		if (!file || !(await openChat())) return;
		companionSelection = {
			selection: { kind: 'pdf', ...capture, filename: file.name },
			revision: (companionSelection?.revision ?? 0) + 1
		};
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
			<header class="flex min-h-11 shrink-0 items-center gap-3 border-b py-2 pr-4 pl-14 md:pl-4">
				<a
					href="{base}/files{file?.folderId ? `/folder/${file.folderId}` : ''}"
					class="shrink-0 rounded-md p-1 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
					aria-label="Back to files"
				>
					<ArrowLeft class="size-4" />
				</a>
				<div class="flex min-w-0 flex-1 items-baseline gap-2">
					<h1 class="min-w-0 truncate text-sm font-semibold" data-testid="file-detail-name">
						{file?.name ?? '…'}
					</h1>
					{#if file}
						<p class="min-w-0 truncate text-xs text-muted-foreground max-md:hidden">
							{formatFileSize(file.fileSize)} · {file.mimeType} · updated {relativeTime(
								file.updatedAt
							)}
						</p>
					{/if}
				</div>
				{#if file}
					{#if isPdf}
						<div class="flex shrink-0 items-center gap-0.5">
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square"
								aria-label="Zoom out"
								title="Zoom out"
								disabled={zoom === ZOOM_STEPS[0]}
								data-testid="pdf-zoom-out"
								onclick={() => zoomBy(-1)}
							>
								<ZoomOut class="size-3.5" />
							</button>
							<button
								type="button"
								class="min-w-11 rounded-md px-1 py-0.5 text-center text-xs tabular-nums text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
								title="Reset zoom"
								data-testid="pdf-zoom-reset"
								onclick={() => (zoom = 100)}
							>
								{zoom}%
							</button>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square"
								aria-label="Zoom in"
								title="Zoom in"
								disabled={zoom === ZOOM_STEPS[ZOOM_STEPS.length - 1]}
								data-testid="pdf-zoom-in"
								onclick={() => zoomBy(1)}
							>
								<ZoomIn class="size-3.5" />
							</button>
						</div>
					{/if}
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
					<div class="flex h-full min-h-0 flex-col">
						<PdfViewer
							url={fileUrl(file)}
							scale={zoom / 100}
							onSelection={(capture) => void onPdfSelection(capture)}
						/>
					</div>
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
					selection={companionSelection ?? undefined}
				/>
			{/await}
		</Resizable.Pane>
	{/if}
</Resizable.PaneGroup>
