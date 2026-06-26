<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import {
		ChevronRight,
		Ellipsis,
		FileText,
		Film,
		Folder as FolderIcon,
		FolderOpen,
		FolderPlus,
		Image as ImageIcon,
		LayoutGrid,
		List,
		ListFilter,
		Mail,
		Search,
		Upload
	} from '@lucide/svelte';
	import {
		fileUrl,
		fileDownloadUrl,
		uploadFile,
		type FileEntry,
		type FolderEntry
	} from '$lib/ash/api';
	import { formatFileSize } from '$lib/files/format';
	import { compactTime } from '$lib/time';
	import { filesStore } from '$lib/stores/files.svelte';
	import { session } from '$lib/stores/session.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import * as Popover from '$lib/components/ui/popover';
	import { EmptyState } from '$lib/components/ui/empty-state';
	import FolderPickerDialog from './folder-picker-dialog.svelte';

	const store = filesStore;

	// Non-default filters in effect — drives the Filters button's count badge.
	const activeFilterCount = $derived(
		[store.filterType, store.filterModified, store.filterSource].filter((value) => value !== 'any')
			.length
	);

	const TITLES: Record<string, string> = {
		my_files: 'My files',
		recent: 'Recent',
		templates: 'Templates',
		trash: 'Trash',
		shared: 'Shared with me',
		knowledge: 'Connected source'
	};

	const canMutate = $derived(
		store.scope === 'my_files' || store.scope === 'folder' || store.scope === 'shared'
	);

	const SORTS: { value: typeof store.sort; label: string }[] = [
		{ value: 'updated_desc', label: 'Modified ↓' },
		{ value: 'updated_asc', label: 'Modified ↑' },
		{ value: 'name_asc', label: 'Name A→Z' },
		{ value: 'name_desc', label: 'Name Z→A' },
		{ value: 'size_desc', label: 'Size ↓' },
		{ value: 'size_asc', label: 'Size ↑' }
	];

	function toggleSort(asc: typeof store.sort, desc: typeof store.sort) {
		store.sort = store.sort === desc ? asc : desc;
	}

	function sourceLabel(file: FileEntry): string {
		if (file.source === 'agent') return 'Generated';
		if (file.source === 'connector') return 'Synced';
		return 'Upload';
	}

	let fileInput = $state<HTMLInputElement | null>(null);
	let uploading = $state(0);
	let dragOver = $state(false);

	let creatingFolder = $state(false);
	let newFolderName = $state('');

	// Inline rename: one entry at a time, same pattern as the chat header.
	let renamingId = $state<string | null>(null);
	let renameDraft = $state('');

	let pickerOpen = $state(false);
	let moving = $state<{ kind: 'file' | 'folder'; id: string } | null>(null);

	function openFolder(id: string) {
		void goto(`${base}/files/folder/${id}`);
	}

	function openFile(id: string) {
		void goto(`${base}/files/file/${id}`);
	}

	async function submitNewFolder() {
		const name = newFolderName.trim();
		creatingFolder = false;
		newFolderName = '';
		if (name) await store.createFolder(name);
	}

	function startRename(id: string, current: string) {
		renamingId = id;
		renameDraft = current;
	}

	async function commitRename(kind: 'file' | 'folder') {
		if (renamingId === null) return;
		const id = renamingId;
		const name = renameDraft.trim();
		renamingId = null;
		if (!name) return;
		if (kind === 'file') await store.renameFile(id, name);
		else await store.renameFolder(id, name);
	}

	function startMove(kind: 'file' | 'folder', id: string) {
		moving = { kind, id };
		pickerOpen = true;
	}

	async function pickMoveTarget(folderId: string | null) {
		if (!moving) return;
		if (moving.kind === 'file') await store.moveFile(moving.id, folderId);
		else await store.moveFolder(moving.id, folderId);
		moving = null;
	}

	async function uploadAll(list: FileList | File[]) {
		const files = Array.from(list);
		if (files.length === 0) return;
		uploading += files.length;

		await Promise.all(
			files.map((file) =>
				uploadFile(file, {
					folderId: store.scope === 'folder' ? (store.folderId ?? undefined) : undefined,
					workspaceId: session.user?.currentWorkspaceId ?? undefined
				}).finally(() => (uploading -= 1))
			)
		);

		store.refresh();
	}

	function onDrop(event: DragEvent) {
		event.preventDefault();
		dragOver = false;
		if (!canMutate) return;
		if (event.dataTransfer?.files) void uploadAll(event.dataTransfer.files);
	}

	function entryIcon(file: FileEntry) {
		switch (file.type) {
			case 'image':
				return ImageIcon;
			case 'video':
				return Film;
			case 'email':
				return Mail;
			default:
				return FileText;
		}
	}
</script>

{#snippet renameInput(kind: 'file' | 'folder')}
	<input
		bind:value={renameDraft}
		data-testid="rename-input"
		class="min-w-0 flex-1 rounded-md border border-input bg-secondary px-2 py-0.5 text-sm outline-none focus:border-primary/60"
		onblur={() => void commitRename(kind)}
		onkeydown={(event) => {
			if (event.key === 'Enter') void commitRename(kind);
			if (event.key === 'Escape') renamingId = null;
		}}
	/>
{/snippet}

{#snippet folderMenu(folder: FolderEntry)}
	<DropdownMenu.Root>
		<DropdownMenu.Trigger
			class="rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
			data-testid="entry-menu"
			aria-label="Folder actions"
		>
			<Ellipsis class="size-4" />
		</DropdownMenu.Trigger>
		<DropdownMenu.Content align="end">
			<DropdownMenu.Item onSelect={() => startRename(folder.id, folder.name)}>
				Rename
			</DropdownMenu.Item>
			<DropdownMenu.Item onSelect={() => startMove('folder', folder.id)}>Move…</DropdownMenu.Item>
			{#if folder.workspaceId}
				<DropdownMenu.Item
					data-testid="folder-share-toggle"
					onSelect={() => void store.toggleFolderShare(folder)}
				>
					{folder.isSharedToWorkspace ? 'Make private' : 'Share with team'}
				</DropdownMenu.Item>
			{/if}
			<DropdownMenu.Separator />
			<DropdownMenu.Item variant="destructive" onSelect={() => void store.deleteFolder(folder.id)}>
				Delete
			</DropdownMenu.Item>
		</DropdownMenu.Content>
	</DropdownMenu.Root>
{/snippet}

{#snippet fileMenu(file: FileEntry)}
	<DropdownMenu.Root>
		<DropdownMenu.Trigger
			class="rounded-md p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
			data-testid="entry-menu"
			aria-label="File actions"
		>
			<Ellipsis class="size-4" />
		</DropdownMenu.Trigger>
		<DropdownMenu.Content align="end">
			<DropdownMenu.Item onSelect={() => openFile(file.id)}>Open</DropdownMenu.Item>
			<DropdownMenu.Item onSelect={() => window.open(fileDownloadUrl(file), '_blank')}>
				Download
			</DropdownMenu.Item>
			{#if canMutate || store.scope === 'templates'}
				<DropdownMenu.Item onSelect={() => startRename(file.id, file.name)}>
					Rename
				</DropdownMenu.Item>
				<DropdownMenu.Item onSelect={() => startMove('file', file.id)}>Move…</DropdownMenu.Item>
				<DropdownMenu.Item onSelect={() => void store.toggleTemplate(file)}>
					{file.isTemplate ? 'Remove from templates' : 'Mark as template'}
				</DropdownMenu.Item>
				{#if file.workspaceId}
					<DropdownMenu.Item
						data-testid="file-share-toggle"
						onSelect={() => void store.toggleFileShare(file)}
					>
						{file.isSharedToWorkspace ? 'Make private' : 'Share with team'}
					</DropdownMenu.Item>
				{/if}
				<DropdownMenu.Separator />
				<DropdownMenu.Item variant="destructive" onSelect={() => void store.trashFile(file.id)}>
					Move to trash
				</DropdownMenu.Item>
			{/if}
		</DropdownMenu.Content>
	</DropdownMenu.Root>
{/snippet}

<!-- svelte-ignore a11y_no_static_element_interactions — drop target wrapper -->
<div
	class="relative flex h-full min-h-0 flex-col"
	data-testid="files-browser"
	ondragover={(event) => {
		event.preventDefault();
		if (canMutate) dragOver = true;
	}}
	ondragleave={() => (dragOver = false)}
	ondrop={onDrop}
>
	{#if dragOver}
		<div
			class="pointer-events-none absolute inset-2 z-10 flex items-center justify-center rounded-xl border-2 border-dashed border-primary bg-primary/5"
		>
			<p class="text-sm font-medium text-primary">Drop to upload</p>
		</div>
	{/if}

	<header class="flex shrink-0 flex-wrap items-center gap-2 border-b px-4 py-2.5">
		<nav class="flex min-w-0 flex-1 items-center gap-1 text-sm" data-testid="files-breadcrumbs">
			{#if store.scope === 'folder'}
				<a href="{base}/files" class="shrink-0 text-muted-foreground hover:text-foreground">
					My files
				</a>
				{#each store.breadcrumbs as crumb, index (crumb.id)}
					<ChevronRight class="size-3.5 shrink-0 text-muted-foreground" />
					{#if index === store.breadcrumbs.length - 1}
						<span class="min-w-0 truncate font-semibold">{crumb.name}</span>
					{:else}
						<a
							href="{base}/files/folder/{crumb.id}"
							class="min-w-0 truncate text-muted-foreground hover:text-foreground"
						>
							{crumb.name}
						</a>
					{/if}
				{/each}
			{:else}
				<span class="font-semibold">{TITLES[store.scope] ?? 'Files'}</span>
			{/if}
		</nav>

		<label
			class="flex w-44 shrink-0 items-center gap-1.5 rounded-md border border-input bg-secondary px-2 py-1 text-xs focus-within:border-ring"
		>
			<Search class="size-3.5 shrink-0 text-muted-foreground" />
			<input
				bind:value={store.query}
				placeholder="Search files"
				aria-label="Search files"
				data-testid="files-search"
				class="min-w-0 flex-1 bg-transparent outline-none"
			/>
		</label>

		<select
			bind:value={store.sort}
			data-testid="files-sort"
			aria-label="Sort files"
			class="shrink-0 rounded-md border border-input bg-secondary px-2 py-1 text-xs outline-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40"
		>
			{#each SORTS as option (option.value)}
				<option value={option.value}>{option.label}</option>
			{/each}
		</select>

		<!-- Classic ?type/modified/source filters, collapsed into a popover so the
		     toolbar stays calm (it wraps on narrow widths). -->
		<Popover.Root>
			<Popover.Trigger
				class="wb-pill-btn shrink-0 {activeFilterCount > 0 ? 'wb-pill-btn-active' : ''}"
				data-testid="files-filters"
				aria-label="Filters"
			>
				<ListFilter class="size-3.5" />
				<span>Filters{activeFilterCount > 0 ? ` (${activeFilterCount})` : ''}</span>
			</Popover.Trigger>
			<Popover.Content align="start" class="flex w-52 flex-col gap-3">
				<label class="flex flex-col gap-1 text-xs">
					<span class="font-medium text-muted-foreground">Type</span>
					<select
						bind:value={store.filterType}
						data-testid="files-filter-type"
						class="rounded-md border border-input bg-secondary px-2 py-1.5 text-xs outline-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40"
					>
						<option value="any">Any type</option>
						<option value="image">Images</option>
						<option value="video">Videos</option>
						<option value="pdf">PDFs</option>
						<option value="document">Documents</option>
						<option value="text">Text</option>
						<option value="email">Emails</option>
					</select>
				</label>
				<label class="flex flex-col gap-1 text-xs">
					<span class="font-medium text-muted-foreground">Modified</span>
					<select
						bind:value={store.filterModified}
						data-testid="files-filter-modified"
						class="rounded-md border border-input bg-secondary px-2 py-1.5 text-xs outline-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40"
					>
						<option value="any">Any time</option>
						<option value="today">Today</option>
						<option value="this_week">This week</option>
						<option value="this_month">This month</option>
						<option value="this_year">This year</option>
						<option value="older">Older</option>
					</select>
				</label>
				<label class="flex flex-col gap-1 text-xs">
					<span class="font-medium text-muted-foreground">Source</span>
					<select
						bind:value={store.filterSource}
						data-testid="files-filter-source"
						class="rounded-md border border-input bg-secondary px-2 py-1.5 text-xs outline-none focus-visible:border-ring focus-visible:ring-2 focus-visible:ring-ring/40"
					>
						<option value="any">Any source</option>
						<option value="uploaded">Uploaded</option>
						<option value="agent">Agent</option>
						<option value="synced">Synced</option>
					</select>
				</label>
			</Popover.Content>
		</Popover.Root>

		{#if canMutate}
			<button
				type="button"
				class="wb-pill-btn shrink-0"
				data-testid="new-folder"
				onclick={() => (creatingFolder = true)}
			>
				<FolderPlus class="size-3.5" />
				<span>New folder</span>
			</button>
			<button
				type="button"
				class="wb-pill-btn shrink-0 !border-primary !bg-primary !text-primary-foreground hover:opacity-90"
				data-testid="files-upload"
				disabled={uploading > 0}
				onclick={() => fileInput?.click()}
			>
				<Upload class="size-3.5" />
				<span>{uploading > 0 ? `Uploading ${uploading}…` : 'Upload'}</span>
			</button>
			<input
				type="file"
				multiple
				hidden
				bind:this={fileInput}
				onchange={(event) => {
					const input = event.currentTarget;
					if (input.files) void uploadAll(input.files);
					input.value = '';
				}}
			/>
		{/if}

		<div
			class="inline-flex shrink-0 overflow-hidden rounded-md border border-input"
			data-testid="files-view-toggle"
		>
			<button
				type="button"
				class="flex items-center justify-center px-2 py-1.5 transition-colors {store.viewMode ===
				'list'
					? 'bg-primary/20 text-primary'
					: 'text-muted-foreground hover:text-foreground'}"
				aria-label="List view"
				onclick={() =>
					store.setViewMode(
						'list',
						(mode) => void session.setUiPreference('files_view_mode', mode)
					)}
			>
				<List class="size-4" />
			</button>
			<button
				type="button"
				class="flex items-center justify-center px-2 py-1.5 transition-colors {store.viewMode ===
				'grid'
					? 'bg-primary/20 text-primary'
					: 'text-muted-foreground hover:text-foreground'}"
				aria-label="Grid view"
				onclick={() =>
					store.setViewMode(
						'grid',
						(mode) => void session.setUiPreference('files_view_mode', mode)
					)}
			>
				<LayoutGrid class="size-4" />
			</button>
		</div>
	</header>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto p-4">
		{#if creatingFolder}
			<form
				class="mb-3 flex max-w-xs items-center gap-2"
				onsubmit={(event) => {
					event.preventDefault();
					void submitNewFolder();
				}}
			>
				<FolderIcon class="size-4 shrink-0 text-muted-foreground" />
				<!-- svelte-ignore a11y_autofocus — transient inline create form -->
				<input
					bind:value={newFolderName}
					autofocus
					placeholder="Folder name"
					data-testid="new-folder-input"
					class="min-w-0 flex-1 rounded-md border border-input bg-secondary px-2 py-1 text-sm outline-none focus:border-primary/60"
					onblur={() => void submitNewFolder()}
					onkeydown={(event) => {
						if (event.key === 'Escape') {
							creatingFolder = false;
							newFolderName = '';
						}
					}}
				/>
			</form>
		{/if}

		{#if store.loading}
			<div class="space-y-2">
				{#each [1, 2, 3, 4, 5] as i (i)}
					<div class="h-9 animate-pulse rounded-md bg-muted"></div>
				{/each}
			</div>
		{:else if store.loadError}
			<p class="text-sm text-destructive">{store.loadError}</p>
		{:else if store.visibleFolders.length === 0 && store.visibleFiles.length === 0}
			{@const EMPTY: Record<string, { title: string; description: string }> = {
				my_files: {
					title: 'No files yet',
					description: 'Upload something, or drop it straight onto this pane.'
				},
				folder: {
					title: 'This folder is empty',
					description: 'Drop files here or upload to fill it.'
				},
				recent: {
					title: 'Nothing recent',
					description: 'Nothing has been modified in the last 30 days.'
				},
				templates: {
					title: 'No templates yet',
					description: 'Mark a file as a template to reuse it here.'
				},
				trash: {
					title: 'Trash is empty',
					description: 'Deleted files appear here before they are purged.'
				},
				shared: {
					title: 'Nothing shared',
					description: 'Nothing has been shared with you yet.'
				},
				knowledge: {
					title: 'No synced files',
					description: 'No files have synced from this source yet.'
				}
			}}
			{@const state = store.query
				? { title: 'No matches', description: 'No files match your search.' }
				: (EMPTY[store.scope] ?? {
						title: 'No files here yet',
						description: 'Upload or drop files to get started.'
					})}
			<EmptyState
				class="h-auto pt-12 pb-8"
				data-testid="files-empty"
				title={state.title}
				description={state.description}
			>
				{#snippet icon()}<FolderOpen />{/snippet}
			</EmptyState>
		{:else}
			{#if store.capped}
				<p
					class="mb-2 rounded-md border border-warning/30 bg-warning/10 px-3 py-1.5 text-xs text-warning"
					data-testid="files-cap-banner"
				>
					Showing the first 500 entries — narrow down with search or filters.
				</p>
			{/if}
			{#if store.viewMode === 'grid'}
				<div class="grid grid-cols-[repeat(auto-fill,minmax(170px,1fr))] gap-3">
					{#each store.visibleFolders as folder (folder.id)}
						<div
							class="group relative flex aspect-[4/5] flex-col overflow-hidden rounded-xl border border-input bg-card/60 transition-colors hover:bg-accent/40"
							data-testid="folder-entry"
						>
							<button
								type="button"
								class="flex min-h-0 flex-1 items-center justify-center"
								onclick={() => openFolder(folder.id)}
							>
								<span class="flex size-14 items-center justify-center rounded-xl bg-primary/10">
									<FolderIcon class="size-7 text-primary" />
								</span>
							</button>
							<div class="border-t border-input px-2 py-1.5">
								{#if renamingId === folder.id}
									{@render renameInput('folder')}
								{:else}
									<button
										type="button"
										class="block w-full truncate text-left text-xs"
										title={folder.name}
										onclick={() => openFolder(folder.id)}
									>
										{folder.name}
									</button>
								{/if}
								<span class="text-[10px] text-muted-foreground/80">Folder</span>
							</div>
							{#if canMutate}
								<div
									class="absolute right-2 top-2 opacity-0 transition-opacity group-hover:opacity-100"
								>
									{@render folderMenu(folder)}
								</div>
							{/if}
						</div>
					{/each}

					{#each store.visibleFiles as file (file.id)}
						{@const Icon = entryIcon(file)}
						<div
							class="group relative flex aspect-[4/5] flex-col overflow-hidden rounded-xl border border-input bg-card/60 transition-colors hover:bg-accent/40"
							data-testid="file-entry"
						>
							<button
								type="button"
								class="flex min-h-0 flex-1 items-center justify-center overflow-hidden"
								onclick={() => openFile(file.id)}
							>
								{#if file.type === 'image'}
									<img
										src={fileUrl(file)}
										alt={file.name}
										loading="lazy"
										class="h-full w-full object-cover"
									/>
								{:else}
									<Icon class="size-8 text-muted-foreground" />
								{/if}
							</button>
							<div class="border-t border-input px-2 py-1.5">
								{#if renamingId === file.id}
									{@render renameInput('file')}
								{:else}
									<button
										type="button"
										class="block w-full truncate text-left text-xs"
										title={file.name}
										onclick={() => openFile(file.id)}
									>
										{file.name}
									</button>
								{/if}
								<span class="text-[10px] text-muted-foreground/80">
									{formatFileSize(file.fileSize)}{file.isTemplate ? ' · Template' : ''}
								</span>
							</div>
							{#if store.scope !== 'trash'}
								<div
									class="absolute right-2 top-2 opacity-0 transition-opacity group-hover:opacity-100"
								>
									{@render fileMenu(file)}
								</div>
							{/if}
						</div>
					{/each}
				</div>
			{:else}
				<table class="w-full text-sm">
					<thead>
						<tr
							class="border-b text-left text-[11px] uppercase tracking-wide text-muted-foreground/80"
						>
							<th
								class="py-1.5 pr-2 font-medium"
								aria-sort={store.sort === 'name_asc'
									? 'ascending'
									: store.sort === 'name_desc'
										? 'descending'
										: 'none'}
							>
								<button
									type="button"
									class="hover:text-foreground"
									onclick={() => toggleSort('name_asc', 'name_desc')}
								>
									Name
								</button>
							</th>
							<th class="w-20 py-1.5 pr-2 font-medium">Type</th>
							<th
								class="w-20 py-1.5 pr-2 text-right font-medium"
								aria-sort={store.sort === 'updated_asc'
									? 'ascending'
									: store.sort === 'updated_desc'
										? 'descending'
										: 'none'}
							>
								<button
									type="button"
									class="hover:text-foreground"
									onclick={() => toggleSort('updated_asc', 'updated_desc')}
								>
									Modified
								</button>
							</th>
							<th
								class="w-20 py-1.5 pr-2 text-right font-medium"
								aria-sort={store.sort === 'size_asc'
									? 'ascending'
									: store.sort === 'size_desc'
										? 'descending'
										: 'none'}
							>
								<button
									type="button"
									class="hover:text-foreground"
									onclick={() => toggleSort('size_asc', 'size_desc')}
								>
									Size
								</button>
							</th>
							<th class="w-24 py-1.5 pr-2 text-right font-medium">Source</th>
							<th class="w-8 py-1.5"></th>
						</tr>
					</thead>
					<tbody>
						{#each store.visibleFolders as folder (folder.id)}
							<tr
								class="group border-b border-border/50 transition-colors hover:bg-accent/40"
								data-testid="folder-entry"
							>
								<td class="py-1.5 pr-2">
									<span class="flex items-center gap-2">
										<FolderIcon class="size-4 shrink-0 text-primary/70" />
										{#if renamingId === folder.id}
											{@render renameInput('folder')}
										{:else}
											<button
												type="button"
												class="min-w-0 truncate text-left"
												onclick={() => openFolder(folder.id)}
											>
												{folder.name}
											</button>
										{/if}
									</span>
								</td>
								<td class="py-1.5 pr-2 text-xs text-muted-foreground">Folder</td>
								<td class="py-1.5 pr-2"></td>
								<td class="py-1.5 pr-2"></td>
								<td class="py-1.5 pr-2"></td>
								<td class="py-1.5 text-right">
									{#if canMutate}
										<span class="opacity-0 transition-opacity group-hover:opacity-100">
											{@render folderMenu(folder)}
										</span>
									{/if}
								</td>
							</tr>
						{/each}

						{#each store.visibleFiles as file (file.id)}
							{@const Icon = entryIcon(file)}
							<tr
								class="group border-b border-border/50 transition-colors hover:bg-accent/40"
								data-testid="file-entry"
							>
								<td class="py-1.5 pr-2">
									<span class="flex items-center gap-2">
										{#if file.type === 'image'}
											<img
												src={fileUrl(file)}
												alt=""
												loading="lazy"
												class="size-5 shrink-0 rounded object-cover"
											/>
										{:else}
											<Icon class="size-4 shrink-0 text-muted-foreground" />
										{/if}
										{#if renamingId === file.id}
											{@render renameInput('file')}
										{:else}
											<button
												type="button"
												class="min-w-0 truncate text-left"
												title={file.name}
												onclick={() => openFile(file.id)}
											>
												{file.name}
											</button>
											{#if file.isTemplate}
												<span
													class="shrink-0 rounded-full border border-input bg-secondary px-1.5 py-0.5 text-[10px] text-secondary-foreground"
												>
													Template
												</span>
											{/if}
										{/if}
									</span>
								</td>
								<td class="py-1.5 pr-2 text-xs capitalize text-muted-foreground">{file.type}</td>
								<td class="py-1.5 pr-2 text-right text-xs text-muted-foreground">
									{compactTime(file.updatedAt)}
								</td>
								<td class="py-1.5 pr-2 text-right text-xs text-muted-foreground">
									{formatFileSize(file.fileSize)}
								</td>
								<td class="py-1.5 pr-2 text-right text-xs text-muted-foreground">
									{sourceLabel(file)}
								</td>
								<td class="py-1.5 text-right">
									{#if store.scope !== 'trash'}
										<span class="opacity-0 transition-opacity group-hover:opacity-100">
											{@render fileMenu(file)}
										</span>
									{/if}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			{/if}
		{/if}
	</div>
</div>

<FolderPickerDialog
	bind:open={pickerOpen}
	excludeId={moving?.kind === 'folder' ? moving.id : null}
	onPick={(folderId) => void pickMoveTarget(folderId)}
/>
