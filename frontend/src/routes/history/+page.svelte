<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { ArchiveRestore, History, MessageSquare, Search, Trash2 } from '@lucide/svelte';
	import MobileNavButton from '$lib/components/shell/mobile-nav-button.svelte';
	import {
		conversationHistory,
		deleteConversationPermanently,
		restoreConversation,
		trashedConversations,
		type HistoryEntry,
		type TrashedConversation
	} from '$lib/ash/api';
	import { relativeTime } from '$lib/time';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';

	const PER_PAGE = 25;

	let tab = $state<'history' | 'trash'>('history');

	// History tab: debounced search + offset pagination.
	let query = $state('');
	let offset = $state(0);
	let entries = $state<HistoryEntry[]>([]);
	let hasMore = $state(false);
	let loading = $state(true);
	let searchTimer: ReturnType<typeof setTimeout> | null = null;

	// Trash tab.
	let trashed = $state<TrashedConversation[]>([]);
	let trashLoading = $state(true);
	let confirmingId = $state<string | null>(null);
	let confirmingEmpty = $state(false);
	let busy = $state(false);

	const workspaceId = $derived(session.user?.currentWorkspaceId ?? null);

	async function loadHistory() {
		loading = true;
		const requested = { query: query.trim(), offset };
		const result = await conversationHistory({
			query: requested.query || undefined,
			workspaceId,
			offset,
			limit: PER_PAGE
		});
		// Drop stale responses (fast typing / page flips).
		if (requested.query !== query.trim() || requested.offset !== offset) return;
		if (result.success) {
			entries = result.data.results;
			hasMore = result.data.hasMore;
		}
		loading = false;
	}

	async function loadTrash() {
		trashLoading = true;
		const result = await trashedConversations();
		if (result.success) trashed = result.data;
		trashLoading = false;
	}

	$effect(() => {
		void workspaceId;
		if (tab === 'history') {
			void loadHistory();
		} else {
			void loadTrash();
		}
	});

	function onSearchInput() {
		if (searchTimer) clearTimeout(searchTimer);
		searchTimer = setTimeout(() => {
			offset = 0;
			void loadHistory();
		}, 250);
	}

	async function openConversation(id: string) {
		await workbench.openTab({ type: 'conversation', id });
		await goto(`${base}/chat/${id}`);
	}

	async function restore(id: string) {
		busy = true;
		const result = await restoreConversation(id);
		busy = false;
		if (result.success) {
			trashed = trashed.filter((entry) => entry.id !== id);
			void workbench.refreshConversations();
		}
	}

	async function destroyForever(id: string) {
		if (confirmingId !== id) {
			confirmingId = id;
			setTimeout(() => (confirmingId = confirmingId === id ? null : confirmingId), 3000);
			return;
		}
		confirmingId = null;
		busy = true;
		const result = await deleteConversationPermanently(id);
		busy = false;
		if (result.success) trashed = trashed.filter((entry) => entry.id !== id);
	}

	async function emptyTrash() {
		if (!confirmingEmpty) {
			confirmingEmpty = true;
			setTimeout(() => (confirmingEmpty = false), 3000);
			return;
		}
		confirmingEmpty = false;
		busy = true;
		for (const entry of trashed) {
			await deleteConversationPermanently(entry.id);
		}
		busy = false;
		await loadTrash();
	}
</script>

<svelte:head>
	<title>Magus — History</title>
</svelte:head>

<div class="flex h-full min-h-0 flex-col" data-testid="history-view">
	<header class="flex min-h-11 shrink-0 items-center gap-2 border-b bg-background/80 py-2 px-6">
		<MobileNavButton />
		<History class="size-4 shrink-0 text-muted-foreground" />
		<h1 class="min-w-0 flex-1 truncate text-base font-semibold">
			{tab === 'trash' ? 'Trash' : 'Conversation history'}
		</h1>
		<div class="flex shrink-0 items-center gap-1.5">
			<button
				type="button"
				class="wb-pill-btn shrink-0 {tab === 'history' ? 'wb-pill-btn-active' : ''}"
				data-testid="history-tab-history"
				onclick={() => (tab = 'history')}
			>
				<History class="size-3.5" />
				<span>History</span>
			</button>
			<button
				type="button"
				class="wb-pill-btn shrink-0 {tab === 'trash' ? 'wb-pill-btn-active' : ''}"
				data-testid="history-tab-trash"
				onclick={() => (tab = 'trash')}
			>
				<Trash2 class="size-3.5" />
				<span>Trash</span>
			</button>
		</div>
	</header>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
		<div class="mx-auto w-full max-w-3xl p-6">
			{#if tab === 'history'}
				<div class="relative mb-4">
					<Search
						class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground"
					/>
					<input
						type="text"
						bind:value={query}
						oninput={onSearchInput}
						placeholder="Search conversations and messages..."
						data-testid="history-search"
						class="w-full rounded-lg border border-input bg-secondary py-2 pr-3 pl-9 text-sm outline-none placeholder:text-muted-foreground focus:border-primary/60"
					/>
				</div>

				{#if loading && entries.length === 0}
					<!-- Quiet load; entries swap in when ready. -->
				{:else if entries.length === 0}
					<p class="py-8 text-center text-sm text-muted-foreground">
						{query ? 'No matches.' : 'No conversations yet.'}
					</p>
				{:else}
					<ul class="flex flex-col gap-1" data-testid="history-list">
						{#each entries as entry (entry.id)}
							<li>
								<button
									type="button"
									class="flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-left transition-colors hover:bg-accent/60"
									onclick={() => void openConversation(entry.id)}
								>
									<MessageSquare class="size-4 shrink-0 text-muted-foreground" />
									<span class="min-w-0 flex-1">
										<span class="block truncate text-sm font-medium">
											{entry.title ?? 'Untitled conversation'}
										</span>
										<span class="block text-xs text-muted-foreground">
											{entry.messageCount}
											{entry.messageCount === 1 ? 'message' : 'messages'}
											· {relativeTime(entry.lastMessageAt ?? entry.updatedAt)}
										</span>
									</span>
								</button>
							</li>
						{/each}
					</ul>

					<div class="mt-4 flex items-center justify-between">
						<button
							type="button"
							class="wb-pill-btn"
							disabled={offset === 0 || loading}
							onclick={() => {
								offset = Math.max(0, offset - PER_PAGE);
								void loadHistory();
							}}
						>
							Previous
						</button>
						<span class="text-xs text-muted-foreground">
							Page {Math.floor(offset / PER_PAGE) + 1}
						</span>
						<button
							type="button"
							class="wb-pill-btn"
							data-testid="history-next"
							disabled={!hasMore || loading}
							onclick={() => {
								offset += PER_PAGE;
								void loadHistory();
							}}
						>
							Next
						</button>
					</div>
				{/if}
			{:else}
				<div class="mb-4 flex items-center justify-between gap-3">
					<p class="text-xs text-muted-foreground">
						Deleted conversations auto-purge after 30 days. Restore or permanently delete.
					</p>
					{#if trashed.length > 0}
						<button
							type="button"
							class="wb-pill-btn shrink-0 {confirmingEmpty
								? '!border-destructive !bg-destructive !text-destructive-foreground'
								: 'hover:!text-destructive'}"
							data-testid="history-empty-trash"
							disabled={busy}
							onclick={() => void emptyTrash()}
						>
							<Trash2 class="size-3.5" />
							<span>{confirmingEmpty ? 'Really empty trash?' : 'Empty trash'}</span>
						</button>
					{/if}
				</div>

				{#if trashLoading && trashed.length === 0}
					<!-- Quiet load. -->
				{:else if trashed.length === 0}
					<p class="py-8 text-center text-sm text-muted-foreground">Trash is empty.</p>
				{:else}
					<ul class="flex flex-col gap-1" data-testid="trash-list">
						{#each trashed as entry (entry.id)}
							<li class="flex items-center gap-3 rounded-lg px-3 py-2.5 hover:bg-accent/40">
								<Trash2 class="size-4 shrink-0 text-muted-foreground" />
								<span class="min-w-0 flex-1">
									<span class="block truncate text-sm font-medium">
										{entry.title ?? 'Untitled conversation'}
									</span>
									<span class="block text-xs text-muted-foreground">
										{entry.messageCount}
										{entry.messageCount === 1 ? 'message' : 'messages'}
										· deleted {relativeTime(entry.deletedAt)}
									</span>
								</span>
								<button
									type="button"
									class="wb-pill-btn shrink-0"
									title="Restore"
									data-testid="trash-restore"
									disabled={busy}
									onclick={() => void restore(entry.id)}
								>
									<ArchiveRestore class="size-3.5" />
									<span>Restore</span>
								</button>
								<button
									type="button"
									class="wb-pill-btn wb-pill-btn-square shrink-0 {confirmingId === entry.id
										? '!border-destructive !bg-destructive !text-destructive-foreground'
										: 'hover:!text-destructive'}"
									aria-label={confirmingId === entry.id ? 'Confirm delete' : 'Delete forever'}
									title="Delete forever"
									data-testid="trash-delete"
									disabled={busy}
									onclick={() => void destroyForever(entry.id)}
								>
									<Trash2 class="size-3.5" />
								</button>
							</li>
						{/each}
					</ul>
				{/if}
			{/if}
		</div>
	</div>
</div>
