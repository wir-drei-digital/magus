<script lang="ts">
	import { File, Image, Search } from '@lucide/svelte';
	import { myLibraryFiles, workspaceLibraryFiles, type FileEntry } from '$lib/ash/api';
	import { formatFileSize } from '$lib/files/format';
	import * as Dialog from '$lib/components/ui/dialog';

	let {
		open = $bindable(false),
		workspaceId = null,
		onPick
	}: {
		open?: boolean;
		/** The brain's workspace (null = personal); scopes which files are listed. */
		workspaceId?: string | null;
		/** Insert the chosen file into the editor as a brain block. */
		onPick: (file: FileEntry) => void;
	} = $props();

	let files = $state<FileEntry[]>([]);
	let query = $state('');

	// Load on open, scoped like the prompt picker: workspace files for a workspace
	// brain, the user's library for a personal one.
	$effect(() => {
		if (!open) return;
		const request = workspaceId ? workspaceLibraryFiles(workspaceId) : myLibraryFiles();
		void request.then((result) => {
			if (result.success) files = result.data;
		});
	});

	const filtered = $derived(
		files.filter((file) => query === '' || file.name.toLowerCase().includes(query.toLowerCase()))
	);

	function pick(file: FileEntry) {
		open = false;
		onPick(file);
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="max-w-md">
		<Dialog.Header>
			<Dialog.Title>Add a file</Dialog.Title>
		</Dialog.Header>

		<label
			class="flex items-center gap-2 rounded-md border border-input bg-secondary px-2 py-1.5 text-sm"
		>
			<Search class="size-4 shrink-0 text-muted-foreground" />
			<input
				bind:value={query}
				placeholder="Search files"
				class="min-w-0 flex-1 bg-transparent outline-none"
			/>
		</label>

		<div class="wb-scroll max-h-72 space-y-0.5 overflow-y-auto" data-testid="brain-file-picker">
			{#each filtered as file (file.id)}
				<button
					type="button"
					class="flex w-full items-start gap-2 rounded-md px-2 py-1.5 text-left text-sm transition-colors hover:bg-accent/60"
					data-testid="brain-file-picker-option"
					onclick={() => pick(file)}
				>
					{#if file.type === 'image'}
						<Image class="mt-0.5 size-3.5 shrink-0 text-muted-foreground" />
					{:else}
						<File class="mt-0.5 size-3.5 shrink-0 text-muted-foreground" />
					{/if}
					<span class="min-w-0">
						<span class="block truncate font-medium">{file.name}</span>
						<span class="block truncate text-xs text-muted-foreground">
							{formatFileSize(file.fileSize)}
						</span>
					</span>
				</button>
			{:else}
				<p class="p-2 text-sm text-muted-foreground">
					{query ? 'No matches.' : 'No files in your library yet.'}
				</p>
			{/each}
		</div>
	</Dialog.Content>
</Dialog.Root>
