<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { base } from '$app/paths';
	import {
		ChevronRight,
		Folder,
		FolderOpen,
		FolderPlus,
		Lock,
		MessageSquare,
		Pencil,
		Plus,
		Star,
		Trash2,
		Users
	} from '@lucide/svelte';
	import type { ConversationSummary } from '$lib/ash/api';
	import { confirmAction } from '$lib/stores/confirm.svelte';
	import { toast } from '$lib/stores/toast.svelte';
	import {
		capConversationGroups,
		groupConversationsByDate,
		navTimestamp
	} from '$lib/chat/nav-grouping';
	import { compactTime } from '$lib/time';
	import { chatNav, type FolderNode } from '$lib/stores/chat-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { conversationPresence } from '$lib/chat/conversation-presence.svelte';
	import { collaborativeConversationIds } from '$lib/chat/conversation-presence';
	import PresenceAvatars from '$lib/components/chat/presence-avatars.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';

	let { query = '' }: { query?: string } = $props();

	let creating = $state(false);
	let favoritesCollapsed = $state(false);
	let renamingFolderId = $state<string | null>(null);
	let renameDraft = $state('');
	let creatingFolder = $state(false);
	let newFolderName = $state('');

	const FILTERS = ['all', 'shared', 'personal'] as const;

	const workspaceId = $derived(session.user?.currentWorkspaceId ?? null);

	$effect(() => {
		void chatNav.load(workspaceId);
	});

	// Nav-row presence: join the per-user feed for the session, then tell it
	// which collaborative conversations are on screen. Two effects so a changing
	// conversation list (new messages reorder rows) only re-pushes the watch set
	// — it never tears down and rejoins the feed.
	$effect(() => {
		const userId = session.user?.id;
		if (!userId) return;
		void conversationPresence.start(userId);
		return () => conversationPresence.stop();
	});

	$effect(() => {
		conversationPresence.watch(collaborativeConversationIds(workbench.conversations));
	});

	const filtered = $derived(
		workbench.conversations.filter(
			(conversation) =>
				query === '' ||
				(conversation.title ?? 'Untitled conversation').toLowerCase().includes(query.toLowerCase())
		)
	);
	const favorites = $derived(filtered.filter((conversation) => conversation.isFavorited));
	const unfavorited = $derived(filtered.filter((conversation) => !conversation.isFavorited));

	const byFolder = $derived.by(() => {
		const map = new Map<string, ConversationSummary[]>();
		for (const conversation of unfavorited) {
			if (!conversation.folderId) continue;
			const list = map.get(conversation.folderId) ?? [];
			list.push(conversation);
			map.set(conversation.folderId, list);
		}
		for (const list of map.values()) {
			list.sort((a, b) => navTimestamp(b).localeCompare(navTimestamp(a)));
		}
		return map;
	});

	const unfiled = $derived(unfavorited.filter((conversation) => !conversation.folderId));

	// Workspace mode splits flat Shared/Personal sections (classic: no date
	// groups in a workspace); personal mode date-groups the unfiled list.
	// The nav shows only the most recent unfiled conversations — the rest
	// live in the history view. Searching bypasses the cap; hiding matches
	// would read as missing results.
	const UNFILED_CAP = 20;
	const sharedUnfiled = $derived.by(() => {
		const shared = unfiled.filter((conversation) => conversation.isSharedToWorkspace);
		return query === '' ? shared.slice(0, UNFILED_CAP) : shared;
	});
	const personalUnfiled = $derived.by(() => {
		const personal = unfiled.filter((conversation) => !conversation.isSharedToWorkspace);
		return query === '' ? personal.slice(0, UNFILED_CAP) : personal;
	});
	const dateGroups = $derived.by(() => {
		const groups = groupConversationsByDate(unfiled);
		return query === '' ? capConversationGroups(groups, UNFILED_CAP) : groups;
	});

	// Workspace mode splits the folder tree into Shared/Personal (classic). The
	// distinction lives on the top-level folder; children render under it.
	const sharedFolders = $derived(chatNav.tree.filter((node) => node.isSharedToWorkspace));
	const personalFolders = $derived(chatNav.tree.filter((node) => !node.isSharedToWorkspace));

	// Drag-drop filing (native HTML5 DnD). The dragged item is held in local
	// state because dataTransfer payloads are unreadable during dragover, which
	// is when a folder row needs to validate + highlight itself as a target.
	let dragItem = $state<{ type: 'conversation' | 'folder'; id: string } | null>(null);
	let dropFolderId = $state<string | null>(null);

	function canDropOn(node: FolderNode): boolean {
		if (!dragItem) return false;
		// A folder can't be filed into itself or its own descendant.
		if (dragItem.type === 'folder') return !chatNav.isSelfOrDescendant(node.id, dragItem.id);
		return true;
	}

	async function dropOn(node: FolderNode) {
		const item = dragItem;
		dragItem = null;
		dropFolderId = null;
		if (!item) return;
		if (item.type === 'conversation') {
			await workbench.moveToFolder(item.id, node.id);
		} else if (item.id !== node.id && !chatNav.isSelfOrDescendant(node.id, item.id)) {
			await chatNav.moveFolder(item.id, node.id);
		}
	}

	/** While searching, folders with matching content are forced open. */
	function folderMatchCount(node: FolderNode): number {
		const own = byFolder.get(node.id)?.length ?? 0;
		return node.children.reduce((sum, child) => sum + folderMatchCount(child), own);
	}

	function folderVisible(node: FolderNode): boolean {
		if (query === '') return true;
		return node.name.toLowerCase().includes(query.toLowerCase()) || folderMatchCount(node) > 0;
	}

	function folderOpenState(node: FolderNode): boolean {
		return query !== '' ? folderMatchCount(node) > 0 : chatNav.isExpanded(node.id);
	}

	async function openConversation(id: string) {
		await workbench.openTab({ type: 'conversation', id }, workbench.conversationTitle(id));
		await goto(`${base}/chat/${id}`);
	}

	async function newConversation(folderId?: string) {
		if (creating) return;
		creating = true;
		const conversation = await workbench.createConversation(folderId ? { folderId } : {});
		creating = false;
		if (conversation) await goto(`${base}/chat/${conversation.id}`);
	}

	async function deleteConversation(conversation: ConversationSummary) {
		const ok = await confirmAction({
			title: 'Delete conversation?',
			description: 'It moves to your archive — you can undo this.',
			confirmLabel: 'Delete'
		});
		if (!ok) return;
		const archived = await workbench.archiveConversation(conversation.id);
		if (!archived) return;
		if (page.url.pathname.endsWith(`/chat/${conversation.id}`)) {
			await goto(`${base}/chat`);
		}
		toast('Conversation deleted', {
			action: { label: 'Undo', run: () => void workbench.restoreConversation(conversation.id) }
		});
	}

	function startRenameFolder(node: FolderNode) {
		renamingFolderId = node.id;
		renameDraft = node.name;
	}

	async function commitRenameFolder() {
		if (!renamingFolderId) return;
		const id = renamingFolderId;
		renamingFolderId = null;
		const name = renameDraft.trim();
		if (name) await chatNav.renameFolder(id, name);
	}

	async function removeFolder(node: FolderNode) {
		const ok = await confirmAction({
			title: `Delete folder "${node.name}"?`,
			description: 'Conversations inside are kept.',
			confirmLabel: 'Delete folder'
		});
		if (!ok) return;
		await chatNav.deleteFolder(node.id);
		await workbench.refreshConversations();
	}

	async function commitNewFolder() {
		if (!creatingFolder) return;
		creatingFolder = false;
		const name = newFolderName.trim();
		newFolderName = '';
		if (name) await chatNav.createFolder(name, workspaceId);
	}
</script>

{#snippet conversationRow(conversation: ConversationSummary)}
	<Sidebar.MenuItem class="group/row">
		<Sidebar.MenuButton
			isActive={page.url.pathname.endsWith(`/chat/${conversation.id}`)}
			draggable={true}
			ondragstart={(event: DragEvent) => {
				dragItem = { type: 'conversation', id: conversation.id };
				if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
			}}
			ondragend={() => {
				dragItem = null;
				dropFolderId = null;
			}}
			onclick={() => void openConversation(conversation.id)}
		>
			<MessageSquare class="text-muted-foreground" />
			<span class="min-w-0 flex-1 truncate">{conversation.title ?? 'Untitled conversation'}</span>
			<!-- Co-viewers on shared rows (empty + self-hiding for solo chats). -->
			<PresenceAvatars
				viewers={conversationPresence.viewers(conversation.id)}
				selfUserId={session.user?.id}
				max={2}
			/>
			<span class="shrink-0 text-[10px] text-muted-foreground group-hover/row:opacity-0">
				{compactTime(navTimestamp(conversation))}
			</span>
		</Sidebar.MenuButton>
		<span
			class="absolute right-1 top-1/2 flex -translate-y-1/2 items-center gap-0.5 rounded-md bg-sidebar-accent pl-1.5 opacity-0 shadow-[-8px_0_8px_-4px_var(--color-sidebar-accent)] transition-opacity group-hover/row:opacity-100"
		>
			{#if workspaceId && conversation.workspaceId}
				<button
					type="button"
					class="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
					title={conversation.isSharedToWorkspace ? 'Make private' : 'Share with team'}
					data-testid="conversation-share-toggle"
					onclick={() => void workbench.toggleWorkspaceShare(conversation.id)}
				>
					{#if conversation.isSharedToWorkspace}
						<Lock class="size-3" />
					{:else}
						<Users class="size-3" />
					{/if}
				</button>
			{/if}
			<button
				type="button"
				class="rounded p-1 hover:bg-accent {conversation.isFavorited
					? 'text-favorite'
					: 'text-muted-foreground hover:text-foreground'}"
				title={conversation.isFavorited ? 'Unfavorite' : 'Favorite'}
				data-testid="conversation-favorite-toggle"
				onclick={() => void workbench.toggleFavorite(conversation.id)}
			>
				<Star class="size-3 {conversation.isFavorited ? 'fill-favorite' : ''}" />
			</button>
			<button
				type="button"
				class="rounded p-1 text-muted-foreground hover:bg-accent hover:text-destructive"
				title="Delete"
				data-testid="conversation-delete"
				onclick={() => void deleteConversation(conversation)}
			>
				<Trash2 class="size-3" />
			</button>
		</span>
	</Sidebar.MenuItem>
{/snippet}

{#snippet folderRow(node: FolderNode)}
	{#if folderVisible(node)}
		{@const open = folderOpenState(node)}
		<Sidebar.MenuItem class="group/folder">
			{#if renamingFolderId === node.id}
				<input
					bind:value={renameDraft}
					class="w-full rounded-md border border-input bg-secondary px-2 py-1 text-sm outline-none focus:border-primary/60"
					data-testid="folder-rename-input"
					onkeydown={(event) => {
						if (event.key === 'Enter') void commitRenameFolder();
						if (event.key === 'Escape') renamingFolderId = null;
					}}
					onblur={() => void commitRenameFolder()}
					{@attach (input) => input.select()}
				/>
			{:else}
				<Sidebar.MenuButton
					data-testid="chat-folder"
					draggable={true}
					class={dropFolderId === node.id ? 'ring-2 ring-primary ring-inset' : ''}
					ondragstart={(event: DragEvent) => {
						event.stopPropagation();
						dragItem = { type: 'folder', id: node.id };
						if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
					}}
					ondragend={() => {
						dragItem = null;
						dropFolderId = null;
					}}
					ondragover={(event: DragEvent) => {
						if (!canDropOn(node)) return;
						event.preventDefault();
						event.stopPropagation();
						dropFolderId = node.id;
					}}
					ondragleave={() => {
						if (dropFolderId === node.id) dropFolderId = null;
					}}
					ondrop={(event: DragEvent) => {
						event.preventDefault();
						event.stopPropagation();
						void dropOn(node);
					}}
					onclick={() => chatNav.toggleFolder(node.id)}
				>
					<ChevronRight class="transition-transform {open ? 'rotate-90' : ''}" />
					{#if open}
						<FolderOpen class="text-muted-foreground" />
					{:else}
						<Folder class="text-muted-foreground" />
					{/if}
					<span class="min-w-0 flex-1 truncate">{node.name}</span>
				</Sidebar.MenuButton>
				{#if open}
					<Sidebar.MenuSub class="mr-0 pr-0">
						{#each node.children as child (child.id)}
							{@render folderRow(child)}
						{/each}
						{#each byFolder.get(node.id) ?? [] as conversation (conversation.id)}
							{@render conversationRow(conversation)}
						{/each}
						{#if query === ''}
							<Sidebar.MenuItem>
								<Sidebar.MenuButton
									class="text-xs text-muted-foreground"
									data-testid="new-chat-in-folder"
									onclick={() => void newConversation(node.id)}
								>
									<Plus />
									<span>New chat</span>
								</Sidebar.MenuButton>
							</Sidebar.MenuItem>
						{/if}
					</Sidebar.MenuSub>
				{/if}
				<span
					class="absolute right-1 top-1.5 flex items-center gap-0.5 rounded-md bg-sidebar-accent pl-1.5 opacity-0 shadow-[-8px_0_8px_-4px_var(--color-sidebar-accent)] transition-opacity group-hover/folder:opacity-100"
				>
					<button
						type="button"
						class="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
						title="Rename folder"
						data-testid="folder-rename"
						onclick={() => startRenameFolder(node)}
					>
						<Pencil class="size-3" />
					</button>
					<button
						type="button"
						class="rounded p-1 text-muted-foreground hover:bg-accent hover:text-destructive"
						title="Delete folder"
						data-testid="folder-delete"
						onclick={() => void removeFolder(node)}
					>
						<Trash2 class="size-3" />
					</button>
				</span>
			{/if}
		</Sidebar.MenuItem>
	{/if}
{/snippet}

{#snippet conversationGroup(
	label: string,
	conversations: ConversationSummary[],
	testid: string | undefined
)}
	{#if conversations.length > 0}
		<Sidebar.Group>
			<Sidebar.GroupLabel>{label}</Sidebar.GroupLabel>
			<Sidebar.GroupContent>
				<Sidebar.Menu data-testid={testid}>
					{#each conversations as conversation (conversation.id)}
						{@render conversationRow(conversation)}
					{/each}
				</Sidebar.Menu>
			</Sidebar.GroupContent>
		</Sidebar.Group>
	{/if}
{/snippet}

{#if workspaceId}
	<div class="flex items-center gap-1 px-3 pt-1">
		{#each FILTERS as filter (filter)}
			<button
				type="button"
				class="rounded-full px-2.5 py-0.5 text-xs capitalize transition-colors {workbench.navFilter ===
				filter
					? 'bg-secondary font-medium text-foreground'
					: 'text-muted-foreground hover:text-foreground'}"
				data-testid="nav-filter-{filter}"
				onclick={() => void workbench.setNavFilter(filter)}
			>
				{filter}
			</button>
		{/each}
	</div>
{/if}

{#if workbench.navLoading || chatNav.loading}
	<Sidebar.Group>
		<Sidebar.GroupContent>
			<Sidebar.Menu>
				{#each [1, 2, 3, 4] as i (i)}
					<Sidebar.MenuItem>
						<Sidebar.MenuSkeleton />
					</Sidebar.MenuItem>
				{/each}
			</Sidebar.Menu>
		</Sidebar.GroupContent>
	</Sidebar.Group>
{:else}
	{#if favorites.length > 0}
		<Sidebar.Group>
			<Sidebar.GroupLabel
				class="w-full hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
			>
				{#snippet child({ props })}
					<button
						type="button"
						{...props}
						data-testid="favorites-toggle"
						onclick={() => (favoritesCollapsed = !favoritesCollapsed)}
					>
						Favorites
						<ChevronRight
							class="ml-auto size-4 transition-transform {favoritesCollapsed ? '' : 'rotate-90'}"
						/>
					</button>
				{/snippet}
			</Sidebar.GroupLabel>
			{#if !favoritesCollapsed}
				<Sidebar.GroupContent>
					<Sidebar.Menu data-testid="conversation-list-favorites">
						{#each favorites as conversation (conversation.id)}
							{@render conversationRow(conversation)}
						{/each}
					</Sidebar.Menu>
				</Sidebar.GroupContent>
			{/if}
		</Sidebar.Group>
	{/if}

	<Sidebar.Group>
		<Sidebar.GroupLabel>Folders</Sidebar.GroupLabel>
		<Sidebar.GroupAction
			title="New folder"
			data-testid="new-folder"
			onclick={() => (creatingFolder = true)}
		>
			<FolderPlus />
			<span class="sr-only">New folder</span>
		</Sidebar.GroupAction>
		<Sidebar.GroupContent>
			{#if creatingFolder}
				<input
					bind:value={newFolderName}
					placeholder="Folder name…"
					class="mx-2 mb-1 w-[calc(100%-1rem)] rounded-md border border-input bg-secondary px-2 py-1 text-sm outline-none focus:border-primary/60"
					data-testid="new-folder-input"
					onkeydown={(event) => {
						if (event.key === 'Enter') void commitNewFolder();
						if (event.key === 'Escape') {
							creatingFolder = false;
							newFolderName = '';
						}
					}}
					onblur={() => void commitNewFolder()}
					{@attach (input) => input.focus()}
				/>
			{/if}
			{#if workspaceId}
				{#if workbench.navFilter !== 'personal' && sharedFolders.length > 0}
					<p
						class="px-2 pt-1 pb-0.5 font-mono text-[10px] font-medium tracking-wider text-muted-foreground uppercase"
					>
						Shared
					</p>
					<Sidebar.Menu data-testid="chat-folder-tree-shared">
						{#each sharedFolders as node (node.id)}
							{@render folderRow(node)}
						{/each}
					</Sidebar.Menu>
				{/if}
				{#if workbench.navFilter !== 'shared' && personalFolders.length > 0}
					<p
						class="px-2 pt-1 pb-0.5 font-mono text-[10px] font-medium tracking-wider text-muted-foreground uppercase"
					>
						Personal
					</p>
					<Sidebar.Menu data-testid="chat-folder-tree">
						{#each personalFolders as node (node.id)}
							{@render folderRow(node)}
						{/each}
					</Sidebar.Menu>
				{/if}
			{:else}
				<Sidebar.Menu data-testid="chat-folder-tree">
					{#each chatNav.tree as node (node.id)}
						{@render folderRow(node)}
					{/each}
				</Sidebar.Menu>
			{/if}
		</Sidebar.GroupContent>
	</Sidebar.Group>

	{#if workspaceId}
		{#if workbench.navFilter !== 'personal'}
			{@render conversationGroup('Shared', sharedUnfiled, 'conversation-list-shared')}
		{/if}
		{#if workbench.navFilter !== 'shared'}
			{@render conversationGroup('Personal', personalUnfiled, 'conversation-list')}
		{/if}
	{:else}
		{#each dateGroups as group, index (group.label)}
			{@render conversationGroup(
				group.label,
				group.conversations,
				index === 0 ? 'conversation-list' : undefined
			)}
		{/each}
	{/if}

	{#if filtered.length === 0 && chatNav.tree.length === 0}
		<p class="p-4 pt-3 text-sm text-muted-foreground">
			{query ? 'No matches.' : 'No conversations yet.'}
		</p>
	{/if}
{/if}
