import {
	createFolder,
	deleteFolder,
	moveFolder,
	myFolders,
	myFolderStates,
	renameFolder,
	upsertFolderExpanded,
	workspaceFolders,
	type FolderEntry
} from '$lib/ash/api';
import { readShellCache, writeShellCache } from '$lib/shell-cache';

export type FolderNode = FolderEntry & { children: FolderNode[] };

/**
 * Chat-nav folder tree: conversation-capable folders plus per-user expansion
 * state persisted via UserFolderState (classic parity). Conversations stay in
 * the workbench store; the nav joins them onto this tree by folderId.
 */
class ChatNavStore {
	folders = $state<FolderEntry[]>([]);
	expanded = $state<Record<string, boolean>>({});
	loading = $state(true);

	#loadedFor: string | null | undefined = undefined;

	async load(workspaceId: string | null): Promise<void> {
		if (this.#loadedFor === workspaceId) return;
		this.#loadedFor = workspaceId;
		this.loading = true;

		// Last-known tree renders instantly; the fetch below reconciles it.
		const cacheKey = `chat-nav:${workspaceId ?? ''}`;
		const snapshot = readShellCache<{
			folders: FolderEntry[];
			expanded: Record<string, boolean>;
		}>(cacheKey);
		if (snapshot) {
			this.folders = snapshot.folders;
			this.expanded = snapshot.expanded;
			this.loading = false;
		}

		const [foldersResult, statesResult] = await Promise.all([
			workspaceId
				? workspaceFolders(workspaceId, ['conversations', 'mixed'])
				: myFolders(['conversations', 'mixed']),
			myFolderStates()
		]);
		if (this.#loadedFor !== workspaceId) return;

		if (foldersResult.success) {
			this.folders = workspaceId
				? foldersResult.data
				: foldersResult.data.filter((folder) => folder.workspaceId === null);
		}
		if (statesResult.success) {
			this.expanded = Object.fromEntries(
				statesResult.data.map((state) => [state.folderId, state.isExpanded])
			);
		}
		this.loading = false;
		if (foldersResult.success) {
			writeShellCache(cacheKey, { folders: this.folders, expanded: this.expanded });
		}
	}

	/** Flat list → nested tree, alphabetical at every level. */
	get tree(): FolderNode[] {
		const byParent = new Map<string | null, FolderEntry[]>();
		for (const folder of this.folders) {
			const list = byParent.get(folder.parentId) ?? [];
			list.push(folder);
			byParent.set(folder.parentId, list);
		}

		const build = (parentId: string | null): FolderNode[] =>
			(byParent.get(parentId) ?? [])
				.slice()
				.sort((a, b) => a.name.localeCompare(b.name))
				.map((folder) => ({ ...folder, children: build(folder.id) }));

		return build(null);
	}

	isExpanded(folderId: string): boolean {
		return this.expanded[folderId] === true;
	}

	/** Optimistic toggle; persisted server-side per user. */
	toggleFolder(folderId: string): void {
		const next = !this.isExpanded(folderId);
		this.expanded = { ...this.expanded, [folderId]: next };
		void upsertFolderExpanded(folderId, next);
	}

	async createFolder(name: string, workspaceId: string | null): Promise<boolean> {
		const result = await createFolder({
			name,
			kind: 'conversations',
			...(workspaceId ? { workspaceId } : {})
		});
		if (!result.success) return false;

		this.folders = [...this.folders, result.data];
		return true;
	}

	async renameFolder(id: string, name: string): Promise<boolean> {
		const result = await renameFolder(id, name);
		if (!result.success) return false;

		this.folders = this.folders.map((folder) => (folder.id === id ? result.data : folder));
		return true;
	}

	/** Deletes the folder; contained conversations become unfiled server-side. */
	async deleteFolder(id: string): Promise<boolean> {
		const result = await deleteFolder(id);
		if (!result.success) return false;

		this.folders = this.folders.filter((folder) => folder.id !== id);
		return true;
	}

	/** Re-parents a folder (drag-drop nesting); `parentId` null moves to root. */
	async moveFolder(id: string, parentId: string | null): Promise<boolean> {
		const result = await moveFolder(id, parentId);
		if (!result.success) return false;

		this.folders = this.folders.map((folder) => (folder.id === id ? result.data : folder));
		return true;
	}

	/** True when `folderId` is `ancestorId` or nested under it (drop guard). */
	isSelfOrDescendant(folderId: string, ancestorId: string): boolean {
		const parentOf = new Map(this.folders.map((folder) => [folder.id, folder.parentId]));
		let current: string | null = folderId;
		while (current) {
			if (current === ancestorId) return true;
			current = parentOf.get(current) ?? null;
		}
		return false;
	}
}

export const chatNav = new ChatNavStore();
