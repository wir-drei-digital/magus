import {
	collectionFiles,
	createFolder,
	deleteFolder,
	folderChildren,
	shareFileToTeam,
	shareFolderToTeam,
	unshareFileFromTeam,
	unshareFolderFromTeam,
	folderFiles,
	getFolder,
	moveFile,
	moveFolder,
	myFolders,
	myLibraryFiles,
	recentFiles,
	renameFolder,
	sharedWithMeFiles,
	templateFiles,
	trashFile,
	trashFiles,
	updateFile,
	workspaceFolders,
	workspaceLibraryFiles,
	type FileEntry,
	type FolderEntry
} from '$lib/ash/api';
import {
	matchesModified,
	matchesSource,
	matchesType,
	type ModifiedFilter,
	type SourceFilter,
	type TypeFilter
} from '$lib/files/filters';

export type FilesScope =
	| 'my_files'
	| 'recent'
	| 'templates'
	| 'trash'
	| 'shared'
	| 'folder'
	| 'knowledge';

export type FilesSort =
	| 'updated_desc'
	| 'updated_asc'
	| 'name_asc'
	| 'name_desc'
	| 'size_desc'
	| 'size_asc';

const RECENT_DAYS = 30;
/** Classic renders at most 500 entries with a truncation banner. */
export const ENTRY_CAP = 500;
const FILE_FOLDER_KINDS: ('files' | 'mixed')[] = ['files', 'mixed'];

/**
 * Files-mode browser state. Loads are keyed by (scope, folderId, workspaceId)
 * so stale responses from a superseded navigation are dropped, mirroring the
 * companion stores. Refreshes are debounced — channel events arrive as
 * id-only hints and a full reload is the classic behavior (150ms debounce).
 */
class FilesStore {
	scope = $state<FilesScope>('my_files');
	folderId = $state<string | null>(null);
	collectionId = $state<string | null>(null);
	files = $state<FileEntry[]>([]);
	folders = $state<FolderEntry[]>([]);
	breadcrumbs = $state<FolderEntry[]>([]);
	loading = $state(true);
	loadError = $state<string | null>(null);

	viewMode = $state<'grid' | 'list'>('list');
	query = $state('');
	sort = $state<FilesSort>('updated_desc');
	filterType = $state<TypeFilter>('any');
	filterModified = $state<ModifiedFilter>('any');
	filterSource = $state<SourceFilter>('any');

	#workspaceId: string | null = null;
	#userId: string | null = null;
	#loadKey = '';
	#refreshTimer: ReturnType<typeof setTimeout> | null = null;

	/** True when the cap trimmed the visible list (drives the banner). */
	get capped(): boolean {
		return this.#matchingFiles().length > ENTRY_CAP;
	}

	#matchingFiles(): FileEntry[] {
		const q = this.query.trim().toLowerCase();
		return this.files.filter(
			(file) =>
				(q === '' || file.name.toLowerCase().includes(q)) &&
				matchesType(file, this.filterType) &&
				matchesModified(file.updatedAt, this.filterModified) &&
				matchesSource(file, this.filterSource)
		);
	}

	/** Search + sort + filters applied client-side over the loaded scope. */
	get visibleFiles(): FileEntry[] {
		const filtered = this.#matchingFiles();

		const compare: Record<FilesSort, (a: FileEntry, b: FileEntry) => number> = {
			updated_desc: (a, b) => b.updatedAt.localeCompare(a.updatedAt),
			updated_asc: (a, b) => a.updatedAt.localeCompare(b.updatedAt),
			name_asc: (a, b) => a.name.localeCompare(b.name),
			name_desc: (a, b) => b.name.localeCompare(a.name),
			size_desc: (a, b) => b.fileSize - a.fileSize,
			size_asc: (a, b) => a.fileSize - b.fileSize
		};
		return filtered.sort(compare[this.sort]).slice(0, ENTRY_CAP);
	}

	get visibleFolders(): FolderEntry[] {
		const q = this.query.trim().toLowerCase();
		return q
			? this.folders.filter((folder) => folder.name.toLowerCase().includes(q))
			: this.folders;
	}

	/** View preference lives in ui_preferences (classic default: grid). */
	restoreViewMode(preferences: Record<string, unknown> | undefined): void {
		const stored = preferences?.['files_view_mode'];
		this.viewMode = stored === 'list' ? 'list' : 'grid';
	}

	setViewMode(mode: 'grid' | 'list', persist: (mode: 'grid' | 'list') => void): void {
		this.viewMode = mode;
		persist(mode);
	}

	async load(
		scope: FilesScope,
		options: {
			folderId?: string | null;
			collectionId?: string | null;
			workspaceId?: string | null;
			userId?: string | null;
		} = {}
	): Promise<void> {
		const folderId = options.folderId ?? null;
		const collectionId = options.collectionId ?? null;
		const workspaceId = options.workspaceId ?? null;
		const userId = options.userId ?? null;
		const key = `${scope}|${folderId ?? ''}|${collectionId ?? ''}|${workspaceId ?? ''}`;

		this.scope = scope;
		this.folderId = folderId;
		this.collectionId = collectionId;
		this.#workspaceId = workspaceId;
		this.#userId = userId;
		this.#loadKey = key;
		this.loading = true;
		this.loadError = null;

		const [filesResult, foldersResult, breadcrumbs] = await Promise.all([
			this.#fetchFiles(scope, folderId, collectionId, workspaceId),
			this.#fetchFolders(scope, folderId, workspaceId),
			scope === 'folder' && folderId ? this.#walkBreadcrumbs(folderId) : Promise.resolve([])
		]);

		if (this.#loadKey !== key) return;

		if (filesResult.success) {
			// The library actions return the whole library; the root view shows
			// only un-foldered entries — and inside a workspace only the actor's
			// own (others' live under "Shared with me"). Mirrors the classic
			// browser's client-side scoping (file_browser_view/data.ex).
			this.files =
				scope === 'my_files'
					? filesResult.data.filter(
							(file) =>
								file.folderId === null && (!workspaceId || !userId || file.userId === userId)
						)
					: filesResult.data;
		} else {
			this.files = [];
			this.loadError = filesResult.errors[0]?.message ?? 'Files could not be loaded';
		}
		this.folders = foldersResult;
		this.breadcrumbs = breadcrumbs;
		this.loading = false;
	}

	/** Channel-event refresh: debounced reload of the current view. */
	refresh(): void {
		if (this.#refreshTimer) clearTimeout(this.#refreshTimer);
		this.#refreshTimer = setTimeout(() => {
			void this.load(this.scope, {
				folderId: this.folderId,
				collectionId: this.collectionId,
				workspaceId: this.#workspaceId,
				userId: this.#userId
			});
		}, 150);
	}

	#fetchFiles(
		scope: FilesScope,
		folderId: string | null,
		collectionId: string | null,
		workspaceId: string | null
	) {
		switch (scope) {
			case 'folder':
				return folderFiles(folderId ?? '');
			case 'knowledge':
				return collectionFiles(collectionId ?? '');
			case 'recent': {
				const since = new Date(Date.now() - RECENT_DAYS * 24 * 60 * 60 * 1000).toISOString();
				return recentFiles(workspaceId, since);
			}
			case 'templates':
				return templateFiles();
			case 'trash':
				return trashFiles(workspaceId);
			case 'shared':
				return sharedWithMeFiles(workspaceId ?? '');
			default:
				return workspaceId ? workspaceLibraryFiles(workspaceId) : myLibraryFiles();
		}
	}

	async #fetchFolders(
		scope: FilesScope,
		folderId: string | null,
		workspaceId: string | null
	): Promise<FolderEntry[]> {
		if (scope === 'folder' && folderId) {
			const result = await folderChildren(folderId, FILE_FOLDER_KINDS);
			return result.success ? result.data : [];
		}

		// Shared scope lists other members' shared root folders (classic).
		if (scope === 'shared' && workspaceId) {
			const result = await workspaceFolders(workspaceId, FILE_FOLDER_KINDS);
			if (!result.success) return [];
			return result.data.filter(
				(folder) =>
					folder.parentId === null && folder.isSharedToWorkspace && folder.userId !== this.#userId
			);
		}

		if (scope !== 'my_files') return [];

		const result = workspaceId
			? await workspaceFolders(workspaceId, FILE_FOLDER_KINDS)
			: await myFolders(FILE_FOLDER_KINDS);
		if (!result.success) return [];
		return result.data.filter((folder) => folder.parentId === null);
	}

	async #walkBreadcrumbs(folderId: string): Promise<FolderEntry[]> {
		const chain: FolderEntry[] = [];
		let current: string | null = folderId;

		// Folder nesting is shallow; the depth cap only guards against cycles.
		for (let depth = 0; current && depth < 10; depth += 1) {
			const result = await getFolder(current);
			if (!result.success) break;
			chain.unshift(result.data);
			current = result.data.parentId;
		}

		return chain;
	}

	// ── Mutations (server-confirmed; the channel hint also refreshes) ────────

	async createFolder(name: string): Promise<FolderEntry | null> {
		const result = await createFolder({
			name,
			kind: 'files',
			parentId: this.scope === 'folder' ? this.folderId : null,
			workspaceId: this.#workspaceId
		});
		if (!result.success) return null;
		this.folders = [...this.folders, result.data].sort((a, b) => a.name.localeCompare(b.name));
		return result.data;
	}

	async renameFolder(id: string, name: string): Promise<boolean> {
		const result = await renameFolder(id, name);
		if (!result.success) return false;
		this.folders = this.folders.map((folder) => (folder.id === id ? result.data : folder));
		this.breadcrumbs = this.breadcrumbs.map((folder) => (folder.id === id ? result.data : folder));
		return true;
	}

	async deleteFolder(id: string): Promise<boolean> {
		const result = await deleteFolder(id);
		if (!result.success) return false;
		this.folders = this.folders.filter((folder) => folder.id !== id);
		return true;
	}

	async moveFolder(id: string, parentId: string | null): Promise<boolean> {
		const result = await moveFolder(id, parentId);
		if (!result.success) return false;
		// Moved away from the current view unless it still belongs here.
		const stillHere =
			(this.scope === 'folder' && parentId === this.folderId) ||
			(this.scope === 'my_files' && parentId === null);
		if (!stillHere) this.folders = this.folders.filter((folder) => folder.id !== id);
		return true;
	}

	async renameFile(id: string, name: string): Promise<boolean> {
		const result = await updateFile(id, { name });
		if (!result.success) return false;
		this.files = this.files.map((file) => (file.id === id ? result.data : file));
		return true;
	}

	async toggleTemplate(file: FileEntry): Promise<boolean> {
		const result = await updateFile(file.id, { isTemplate: !file.isTemplate });
		if (!result.success) return false;
		this.files = this.files.map((entry) => (entry.id === file.id ? result.data : entry));
		return true;
	}

	/** Share/unshare with the workspace (file: viewer grant; folder cascades). */
	async toggleFileShare(file: FileEntry): Promise<boolean> {
		const result = file.isSharedToWorkspace
			? await unshareFileFromTeam(file.id)
			: await shareFileToTeam(file.id);
		if (!result.success) return false;
		this.files = this.files.map((entry) => (entry.id === file.id ? result.data : entry));
		return true;
	}

	async toggleFolderShare(folder: FolderEntry): Promise<boolean> {
		const result = folder.isSharedToWorkspace
			? await unshareFolderFromTeam(folder.id)
			: await shareFolderToTeam(folder.id);
		if (!result.success) return false;
		this.folders = this.folders.map((entry) => (entry.id === folder.id ? result.data : entry));
		return true;
	}

	async trashFile(id: string): Promise<boolean> {
		const result = await trashFile(id);
		if (!result.success) return false;
		this.files = this.files.filter((file) => file.id !== id);
		return true;
	}

	async moveFile(id: string, folderId: string | null): Promise<boolean> {
		const result = await moveFile(id, { folderId });
		if (!result.success) return false;
		const stillHere =
			(this.scope === 'folder' && folderId === this.folderId) ||
			(this.scope === 'my_files' && folderId === null);
		if (!stillHere) this.files = this.files.filter((file) => file.id !== id);
		return true;
	}
}

export const filesStore = new FilesStore();
