<script lang="ts">
	import { Download, File as FileIcon, Trash2, Upload } from '@lucide/svelte';
	import {
		conversationFiles,
		fileDownloadUrl,
		myLibraryFiles,
		trashFile,
		uploadFile,
		workspaceLibraryFiles,
		type FileEntry
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import { formatFileSize } from '$lib/files/format';
	import { relativeTime } from '$lib/time';

	let { conversationId }: { conversationId: string } = $props();

	type Scope = 'chat' | 'team' | 'global';

	const workspaceId = $derived(session.user?.currentWorkspaceId ?? null);

	let scope = $state<Scope>('chat');
	let files = $state<FileEntry[]>([]);
	let loading = $state(true);
	let uploading = $state(0);
	let error = $state<string | null>(null);
	let fileInput = $state<HTMLInputElement | null>(null);

	// Reload when the scope, conversation, or workspace changes. Dependencies
	// are captured here explicitly so load() itself tracks nothing extra.
	let loadSequence = 0;
	$effect(() => {
		void load(scope, conversationId, workspaceId);
	});

	async function load(forScope: Scope, forConversationId: string, forWorkspaceId: string | null) {
		const sequence = ++loadSequence;
		loading = true;
		const result =
			forScope === 'chat'
				? await conversationFiles(forConversationId)
				: forScope === 'team' && forWorkspaceId
					? await workspaceLibraryFiles(forWorkspaceId)
					: await myLibraryFiles();
		// A newer load superseded this one (fast scope switching) — drop it.
		if (sequence !== loadSequence) return;
		if (result.success) files = result.data;
		loading = false;
	}

	async function upload(selected: FileList | File[]) {
		error = null;
		const list = Array.from(selected);
		uploading += list.length;
		for (const file of list) {
			const target =
				scope === 'chat'
					? { conversationId }
					: scope === 'team' && workspaceId
						? { workspaceId }
						: {};
			const result = await uploadFile(file, target);
			uploading -= 1;
			if (!result.success) error = result.errors[0]?.message ?? 'Upload failed';
		}
		void load(scope, conversationId, workspaceId);
	}

	async function remove(file: FileEntry) {
		error = null;
		const result = await trashFile(file.id);
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Could not delete file';
			return;
		}
		files = files.filter((entry) => entry.id !== file.id);
	}
</script>

<div class="flex min-h-0 flex-1 flex-col" data-testid="rail-files-panel">
	<div class="flex items-center gap-1 border-b p-2.5 text-xs">
		<button
			type="button"
			class="rounded-md px-2 py-1 font-medium transition-colors {scope === 'chat'
				? 'bg-secondary text-foreground'
				: 'text-muted-foreground hover:text-foreground'}"
			data-testid="rail-files-scope-chat"
			onclick={() => (scope = 'chat')}
		>
			Chat
		</button>
		{#if workspaceId}
			<button
				type="button"
				class="rounded-md px-2 py-1 font-medium transition-colors {scope === 'team'
					? 'bg-secondary text-foreground'
					: 'text-muted-foreground hover:text-foreground'}"
				onclick={() => (scope = 'team')}
			>
				Team
			</button>
		{/if}
		<button
			type="button"
			class="rounded-md px-2 py-1 font-medium transition-colors {scope === 'global'
				? 'bg-secondary text-foreground'
				: 'text-muted-foreground hover:text-foreground'}"
			onclick={() => (scope = 'global')}
		>
			Global
		</button>

		<button
			type="button"
			class="ml-auto inline-flex items-center gap-1 rounded-md px-2 py-1 text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
			data-testid="rail-upload-file"
			onclick={() => fileInput?.click()}
		>
			<Upload class="size-3.5" />
			Upload
		</button>
		<input
			bind:this={fileInput}
			type="file"
			multiple
			class="hidden"
			onchange={(event) => {
				const selected = event.currentTarget.files;
				if (selected && selected.length > 0) void upload(selected);
				event.currentTarget.value = '';
			}}
		/>
	</div>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto p-1.5">
		{#if error}
			<p class="p-2 text-xs text-destructive">{error}</p>
		{/if}
		{#if uploading > 0}
			<p class="flex items-center gap-1.5 p-2 text-xs text-muted-foreground">
				<span class="size-3 animate-spin rounded-full border-2 border-current border-t-transparent"
				></span>
				Uploading…
			</p>
		{/if}
		{#if loading}
			<div class="space-y-2 p-1">
				{#each [1, 2, 3] as i (i)}
					<div class="h-10 animate-pulse rounded-md bg-muted"></div>
				{/each}
			</div>
		{:else if files.length === 0}
			<p class="p-2 text-xs text-muted-foreground">No files in this scope.</p>
		{:else}
			<ul class="space-y-0.5">
				{#each files as file (file.id)}
					<li
						class="group flex items-center gap-2 rounded-md px-2 py-1.5 transition-colors hover:bg-accent/60"
					>
						<FileIcon class="size-3.5 shrink-0 text-muted-foreground" />
						<span class="min-w-0 flex-1">
							<span class="block truncate text-xs font-medium">{file.name}</span>
							<span class="block text-[11px] text-muted-foreground">
								{formatFileSize(file.fileSize)} · {relativeTime(file.updatedAt)}
								{#if file.status !== 'ready'}
									· <span class={file.status === 'error' ? 'text-destructive' : ''}
										>{file.status}</span
									>
								{/if}
							</span>
						</span>
						<a
							href={fileDownloadUrl(file)}
							download
							class="shrink-0 rounded-md p-1 text-muted-foreground opacity-0 transition-opacity hover:text-foreground group-hover:opacity-100"
							title="Download"
						>
							<Download class="size-3.5" />
						</a>
						<button
							type="button"
							class="shrink-0 rounded-md p-1 text-muted-foreground opacity-0 transition-opacity hover:text-destructive group-hover:opacity-100"
							title="Move to trash"
							onclick={() => void remove(file)}
						>
							<Trash2 class="size-3.5" />
						</button>
					</li>
				{/each}
			</ul>
		{/if}
	</div>
</div>
