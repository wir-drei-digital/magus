import {
	activateWorkbenchTab,
	archiveConversation,
	closeWorkbenchTab,
	conversationsThreads,
	createConversation,
	favoriteConversation,
	moveConversationToFolder,
	removeConversationFavorite,
	getOrCreateTabSession,
	myWorkspaces,
	openWorkbenchTab,
	personalConversations,
	renameConversation,
	restoreConversation,
	setTabSessionMode,
	setTabSessionNavFilter,
	setWorkbenchCompanion,
	shareConversationToTeam,
	startSkillConversation,
	unshareConversationFromTeam,
	workspaceConversations,
	type CompanionSpec,
	type ConversationSummary,
	type ThreadNavSummary,
	type TabSession,
	type WorkbenchTab,
	type WorkspaceSummary
} from '$lib/ash/api';
import { groupThreadsByParent } from '$lib/chat/thread-nav';
import { untrack } from 'svelte';
import { modeFromPath } from '$lib/route-mode';
import { readShellCache, writeShellCache } from '$lib/shell-cache';
import { session } from '$lib/stores/session.svelte';

export type WorkbenchMode = TabSession['mode'];

/**
 * Client-side placeholder tabs from openTab that the server hasn't
 * acknowledged yet. These ids must never reach the server: ActivateTab &
 * friends reject unknown ids, and the rollback would restore the very state
 * that triggered the call, looping forever. Exported so callers can defer
 * server-persisted tab mutations (e.g. companions) until the tab is canonical.
 */
export const isOptimisticTabId = (tabId: string) => tabId.startsWith('optimistic-');

/**
 * Workbench shell state: the persisted TabSession (optimistically mutated,
 * reconciled with each RPC response) plus the conversation nav and workspace
 * list. Cross-device sync is refetch-on-focus for now — TabSession changes
 * are not broadcast today and broadcast shapes are frozen during migration.
 */
class WorkbenchStore {
	session = $state<TabSession | null>(null);
	conversations = $state<ConversationSummary[]>([]);
	threadsByParent = $state<Map<string, ThreadNavSummary[]>>(new Map());
	workspaces = $state<WorkspaceSummary[]>([]);
	navLoading = $state(true);

	/** Workspace context from load(); scopes conversation reads and creates. */
	workspaceId: string | null = null;

	/** Actor from load(); lets failed mutations refetch the canonical session. */
	#userId: string | null = null;

	/**
	 * Monotonic mutation counter for TabSession writes. Every mutation applies
	 * optimistically, then reconciles with the server response ONLY if no newer
	 * mutation started in the meantime — otherwise a slow in-flight response
	 * (e.g. openTab carrying the old mode) would clobber a later optimistic
	 * change (e.g. setMode). Stale failures also defer to the newer state.
	 */
	#mutationSeq = 0;

	/** Mode clicked before the initial load resolved; applied once it does. */
	#pendingMode: WorkbenchMode | null = null;

	/** Cache key the current session/conversations were hydrated under. */
	#snapshotKey: string | null = null;

	#snapshotKeyFor(userId: string, workspaceId: string | null): string {
		return `workbench:${userId}:${workspaceId ?? ''}`;
	}

	/** Persists the shell snapshot for instant hydration on the next boot. */
	#persistSnapshot(): void {
		if (!this.#snapshotKey || !this.session) return;
		writeShellCache(this.#snapshotKey, {
			session: this.session,
			conversations: this.conversations
		});
	}

	async #reconcile(
		previous: TabSession,
		mutate: () => Promise<{ success: true; data: TabSession } | { success: false }>
	): Promise<void> {
		const seq = ++this.#mutationSeq;
		const result = await mutate();
		if (seq !== this.#mutationSeq) return;
		if (result.success) {
			this.session = result.data;
			this.#persistSnapshot();
			return;
		}

		// Even `previous` can have diverged from the server (e.g. it may hold an
		// optimistic tab whose open_tab response got dropped by a newer mutation).
		// Roll back for immediacy, then refetch the canonical session.
		this.session = previous;
		if (!this.#userId) return;
		const fresh = await getOrCreateTabSession(this.#userId, this.workspaceId);
		if (seq === this.#mutationSeq && fresh.success) this.session = fresh.data;
	}

	get mode(): WorkbenchMode {
		if (this.session) {
			const mode = this.session.mode;
			// Saved sessions may still hold the pre-merge modes.
			return mode === 'prompts' || mode === 'skills' ? 'library' : mode;
		}
		// Pre-session fallback: reloading on /brain/... must not flash the
		// chat nav while the TabSession round trip is in flight.
		if (typeof location !== 'undefined') return modeFromPath(location.pathname);
		return 'chat';
	}

	get tabs(): WorkbenchTab[] {
		return this.session?.tabs ?? [];
	}

	get activeTabId(): string | null {
		return this.session?.activeTabId ?? null;
	}

	get navFilter(): TabSession['navFilter'] {
		return this.session?.navFilter ?? 'all';
	}

	/**
	 * Classic parity: tabs are opt-in via `ui_preferences.tabs_enabled`
	 * (default off). When off, the tab bar is hidden and the session never
	 * holds more than the active tab — openTab trims like the classic
	 * shell's maybe_trim_to_active_tab.
	 */
	get tabsEnabled(): boolean {
		return session.user?.uiPreferences?.['tabs_enabled'] === true;
	}

	async setNavFilter(navFilter: TabSession['navFilter']): Promise<void> {
		if (!this.session || this.session.navFilter === navFilter) return;
		const previous = this.session;
		this.session = { ...previous, navFilter };

		await this.#reconcile(previous, () => setTabSessionNavFilter(previous.id, navFilter));
	}

	async load(userId: string, workspaceId: string | null): Promise<void> {
		this.workspaceId = workspaceId;
		this.#userId = userId;

		// Hydrate from the last snapshot when entering a new user/workspace
		// context (boot or workspace switch) — the nav renders instantly with
		// last-known state while the fetches below reconcile it. Focus
		// refetches keep the live state.
		const key = this.#snapshotKeyFor(userId, workspaceId);
		if (this.#snapshotKey !== key) {
			this.#snapshotKey = key;
			const snapshot = readShellCache<{
				session: TabSession;
				conversations: ConversationSummary[];
			}>(key);
			if (snapshot && this.#mutationSeq === 0) {
				this.session = snapshot.session;
				this.conversations = snapshot.conversations;
				this.navLoading = false;
			}
		}

		const seqAtStart = this.#mutationSeq;

		const [sessionResult, conversationsResult, workspacesResult] = await Promise.all([
			getOrCreateTabSession(userId, workspaceId),
			workspaceId ? workspaceConversations(workspaceId) : personalConversations(),
			myWorkspaces()
		]);

		// A mutation that started while this (focus-triggered) refetch was in
		// flight owns the session now — its snapshot would be stale.
		if (sessionResult.success && this.#mutationSeq === seqAtStart) {
			this.session = sessionResult.data;
		}

		// A mode click that raced the initial load applies now.
		if (this.#pendingMode && this.session) {
			const mode = this.#pendingMode;
			this.#pendingMode = null;
			void this.setMode(mode);
		}
		if (conversationsResult.success) {
			this.conversations = conversationsResult.data
				.slice()
				.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
		}
		if (conversationsResult.success) {
			void this.#loadThreadsFor(conversationsResult.data.map((c) => c.id));
		}
		if (workspacesResult.success) this.workspaces = workspacesResult.data;
		this.navLoading = false;
		this.#persistSnapshot();
	}

	async #loadThreadsFor(conversationIds: string[]): Promise<void> {
		const seqAtStart = this.#mutationSeq;
		const result = await conversationsThreads(conversationIds);
		if (result.success && this.#mutationSeq === seqAtStart) {
			this.threadsByParent = groupThreadsByParent(result.data);
		}
	}

	async refreshConversations(): Promise<void> {
		const result = this.workspaceId
			? await workspaceConversations(this.workspaceId)
			: await personalConversations();
		if (result.success) {
			this.conversations = result.data
				.slice()
				.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
			this.#persistSnapshot();
			void this.#loadThreadsFor(result.data.map((c) => c.id));
		}
	}

	async setMode(mode: WorkbenchMode): Promise<void> {
		if (!this.session) {
			this.#pendingMode = mode;
			return;
		}
		const previous = this.session;
		this.session = { ...previous, mode };

		await this.#reconcile(previous, () => setTabSessionMode(previous.id, mode));
	}

	/** Opens (or focuses) a tab for a primary resource. Optimistic; reconciled. */
	async openTab(primary: WorkbenchTab['primary'], label?: string): Promise<void> {
		if (!this.session) return;
		const previous = this.session;
		// untrack: openTab runs inside the pages' deep-link $effects; reading
		// session.user there would re-trigger them on every user replacement.
		const tabsEnabled = untrack(() => this.tabsEnabled);

		const existing = previous.tabs.find(
			(tab) => tab.primary.type === primary.type && tab.primary.id === primary.id
		);

		// With tabs enabled (or an already-singular session) focusing suffices.
		if (existing && (tabsEnabled || previous.tabs.length === 1)) {
			return this.activateTab(existing.id);
		}

		const optimistic: WorkbenchTab = existing ?? {
			id: `optimistic-${crypto.randomUUID()}`,
			primary: label ? { ...primary, label } : primary
		};

		this.session = {
			...previous,
			tabs: tabsEnabled ? [...previous.tabs, optimistic] : [optimistic],
			activeTabId: optimistic.id
		};

		// Classic maybe_trim_to_active_tab: with tabs disabled the shell only
		// renders the active resource, so open-and-trim server-side in one round
		// trip (single: true) instead of a follow-up replace_tabs call.
		await this.#reconcile(previous, () =>
			openWorkbenchTab(previous.id, primary, label, { single: !tabsEnabled })
		);
	}

	async activateTab(tabId: string): Promise<void> {
		if (!this.session || this.session.activeTabId === tabId) return;
		const previous = this.session;
		this.session = { ...previous, activeTabId: tabId };

		// The pending openTab reconcile delivers the canonical id; local-only.
		if (isOptimisticTabId(tabId)) return;
		await this.#reconcile(previous, () => activateWorkbenchTab(previous.id, tabId));
	}

	async closeTab(tabId: string): Promise<void> {
		if (!this.session) return;
		const previous = this.session;
		const tabs = previous.tabs.filter((tab) => tab.id !== tabId);
		const activeTabId =
			previous.activeTabId === tabId ? (tabs.at(-1)?.id ?? null) : previous.activeTabId;
		this.session = { ...previous, tabs, activeTabId };

		if (isOptimisticTabId(tabId)) return;
		await this.#reconcile(previous, () => closeWorkbenchTab(previous.id, tabId));
	}

	/** The tab whose primary is the given conversation, if open. */
	tabForConversation(conversationId: string): WorkbenchTab | null {
		return (
			this.tabs.find(
				(tab) => tab.primary.type === 'conversation' && tab.primary.id === conversationId
			) ?? null
		);
	}

	/**
	 * Sets (or clears) a tab's companion pane. Optimistic, like every other
	 * tab mutation; opening the same companion twice is a no-op.
	 */
	async setCompanion(tabId: string, companion: CompanionSpec | null): Promise<void> {
		if (!this.session) return;
		const previous = this.session;

		const tab = previous.tabs.find((entry) => entry.id === tabId);
		if (!tab) return;
		const current = tab.companion ?? null;
		if (current?.type === companion?.type && current?.id === companion?.id) return;

		this.session = {
			...previous,
			tabs: previous.tabs.map((entry) => (entry.id === tabId ? { ...entry, companion } : entry))
		};

		if (isOptimisticTabId(tabId)) return;
		await this.#reconcile(previous, () => setWorkbenchCompanion(previous.id, tabId, companion));
	}

	conversationTitle(id: string): string {
		return this.conversations.find((conversation) => conversation.id === id)?.title ?? 'Chat';
	}

	conversation(id: string): ConversationSummary | null {
		return this.conversations.find((conversation) => conversation.id === id) ?? null;
	}

	/** Threads branched off a conversation, oldest first (empty when none). */
	threadsFor(conversationId: string): ThreadNavSummary[] {
		return this.threadsByParent.get(conversationId) ?? [];
	}

	/** Reload nav threads for the currently loaded conversations. */
	async refreshThreads(): Promise<void> {
		await this.#loadThreadsFor(this.conversations.map((c) => c.id));
	}

	/** Soft-deletes a thread (a child conversation) and drops it from the nav. */
	async deleteThread(threadId: string, parentConversationId: string): Promise<boolean> {
		const result = await archiveConversation(threadId);
		if (!result.success) return false;

		const list = this.threadsByParent.get(parentConversationId);
		if (list) {
			const next = list.filter((thread) => thread.id !== threadId);
			const map = new Map(this.threadsByParent);
			if (next.length > 0) map.set(parentConversationId, next);
			else map.delete(parentConversationId);
			this.threadsByParent = map;
		}
		return true;
	}

	/**
	 * Creates a conversation in the current workspace context (and optionally
	 * a folder or with a seeded agent), prepends it to the nav, opens its tab.
	 */
	async createConversation(
		options: { folderId?: string; customAgentId?: string } = {}
	): Promise<ConversationSummary | null> {
		const result = await createConversation({
			workspaceId: this.workspaceId,
			...(options.folderId ? { folderId: options.folderId } : {}),
			...(options.customAgentId ? { customAgentId: options.customAgentId } : {})
		});
		if (!result.success) return null;

		const conversation = result.data;
		this.conversations = [conversation, ...this.conversations];
		await this.openTab(
			{ type: 'conversation', id: conversation.id },
			conversation.title ?? undefined
		);
		return conversation;
	}

	/**
	 * Starts a skill-seeded conversation in the current workspace context
	 * (classic ?skill= deeplink), prepends it to the nav, and opens its tab.
	 */
	async startSkillConversation(input: {
		skillName: string;
		topic?: string | null;
	}): Promise<ConversationSummary | null> {
		const result = await startSkillConversation({
			skillName: input.skillName,
			...(input.topic ? { topic: input.topic } : {}),
			workspaceId: this.workspaceId
		});
		if (!result.success) return null;

		const conversation = result.data;
		this.conversations = [conversation, ...this.conversations];
		await this.openTab(
			{ type: 'conversation', id: conversation.id },
			conversation.title ?? undefined
		);
		return conversation;
	}

	async renameConversation(id: string, title: string): Promise<boolean> {
		const result = await renameConversation(id, title);
		if (!result.success) return false;

		this.upsertConversation(result.data);
		return true;
	}

	/** Soft-deletes the conversation, drops it from the nav, closes its tab. */
	async archiveConversation(id: string): Promise<boolean> {
		const result = await archiveConversation(id);
		if (!result.success) return false;

		this.conversations = this.conversations.filter((conversation) => conversation.id !== id);
		this.#persistSnapshot();
		const tab = this.tabs.find(
			(entry) => entry.primary.type === 'conversation' && entry.primary.id === id
		);
		if (tab) await this.closeTab(tab.id);
		return true;
	}

	/** Restores a soft-deleted conversation and re-adds it to the nav (undo). */
	async restoreConversation(id: string): Promise<boolean> {
		const result = await restoreConversation(id);
		if (!result.success) return false;
		this.upsertConversation(result.data);
		return true;
	}

	/** Star/unstar a conversation; the nav Favorites section reflects it. */
	async toggleFavorite(id: string): Promise<void> {
		const conversation = this.conversation(id);
		if (!conversation) return;

		if (conversation.isFavorited) {
			await removeConversationFavorite(id);
		} else {
			await favoriteConversation(id);
		}

		this.upsertConversation({ ...conversation, isFavorited: !conversation.isFavorited });
	}

	/** Share/unshare a workspace conversation with the team (classic nav action). */
	async toggleWorkspaceShare(id: string): Promise<boolean> {
		const conversation = this.conversation(id);
		if (!conversation || !conversation.workspaceId) return false;

		const result = conversation.isSharedToWorkspace
			? await unshareConversationFromTeam(id)
			: await shareConversationToTeam(id);
		if (!result.success) return false;

		this.upsertConversation(result.data);
		return true;
	}

	/** Files (or unfiles, with null) a conversation into a folder. */
	async moveToFolder(id: string, folderId: string | null): Promise<boolean> {
		const result = await moveConversationToFolder(id, folderId);
		if (!result.success) return false;

		this.upsertConversation(result.data);
		return true;
	}

	/** Reconcile a server-updated conversation row into the nav list. */
	upsertConversation(conversation: ConversationSummary): void {
		const index = this.conversations.findIndex((entry) => entry.id === conversation.id);
		if (index >= 0) {
			const next = this.conversations.slice();
			next[index] = conversation;
			this.conversations = next;
		} else {
			this.conversations = [conversation, ...this.conversations];
		}
		this.#persistSnapshot();
	}

	/** Reconcile a workspace into the switcher list (e.g. after create/rename). */
	upsertWorkspace(workspace: WorkspaceSummary): void {
		const index = this.workspaces.findIndex((entry) => entry.id === workspace.id);
		if (index >= 0) {
			const next = this.workspaces.slice();
			next[index] = workspace;
			this.workspaces = next;
		} else {
			this.workspaces = [...this.workspaces, workspace];
		}
	}

	/** Drop a workspace from the switcher list (e.g. after deactivation). */
	removeWorkspace(id: string): void {
		this.workspaces = this.workspaces.filter((workspace) => workspace.id !== id);
	}
}

export const workbench = new WorkbenchStore();
