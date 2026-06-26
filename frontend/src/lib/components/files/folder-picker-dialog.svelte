<script lang="ts">
	import { Folder as FolderIcon, Home } from '@lucide/svelte';
	import { myFolders, workspaceFolders, type FolderEntry } from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import * as Dialog from '$lib/components/ui/dialog';

	let {
		open = $bindable(false),
		excludeId = null,
		onPick
	}: {
		open?: boolean;
		/** Folder being moved — excluded (with its subtree root) from targets. */
		excludeId?: string | null;
		onPick: (folderId: string | null) => void;
	} = $props();

	let folders = $state<FolderEntry[]>([]);

	// Flat list indented by depth, computed from parent links. Folders whose
	// parent isn't in the (policy-filtered, exclusion-pruned) set re-parent to
	// root so they stay reachable instead of silently vanishing.
	const tree = $derived.by(() => {
		const visible = folders.filter((folder) => folder.id !== excludeId);
		const ids = new Set(visible.map((folder) => folder.id));

		const byParent = new Map<string | null, FolderEntry[]>();
		for (const folder of visible) {
			const parent = folder.parentId !== null && ids.has(folder.parentId) ? folder.parentId : null;
			const list = byParent.get(parent) ?? [];
			list.push(folder);
			byParent.set(parent, list);
		}

		const rows: { folder: FolderEntry; depth: number }[] = [];
		const walk = (parentId: string | null, depth: number) => {
			for (const folder of byParent.get(parentId) ?? []) {
				rows.push({ folder, depth });
				walk(folder.id, depth + 1);
			}
		};
		walk(null, 0);
		return rows;
	});

	$effect(() => {
		if (!open) return;
		const workspaceId = session.user?.currentWorkspaceId ?? null;
		const request = workspaceId
			? workspaceFolders(workspaceId, ['files', 'mixed'])
			: myFolders(['files', 'mixed']);
		void request.then((result) => {
			if (result.success) folders = result.data;
		});
	});

	function pick(folderId: string | null) {
		open = false;
		onPick(folderId);
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="max-w-sm">
		<Dialog.Header>
			<Dialog.Title>Move to folder</Dialog.Title>
		</Dialog.Header>

		<div class="wb-scroll max-h-72 space-y-0.5 overflow-y-auto" data-testid="folder-picker">
			<button
				type="button"
				class="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm transition-colors hover:bg-accent/60"
				data-testid="folder-picker-root"
				onclick={() => pick(null)}
			>
				<Home class="size-4 text-muted-foreground" />
				<span>Library root</span>
			</button>

			{#each tree as row (row.folder.id)}
				<button
					type="button"
					class="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm transition-colors hover:bg-accent/60"
					style="padding-left: {8 + row.depth * 16}px"
					onclick={() => pick(row.folder.id)}
				>
					<FolderIcon class="size-4 text-muted-foreground" />
					<span class="min-w-0 truncate">{row.folder.name}</span>
				</button>
			{/each}
		</div>
	</Dialog.Content>
</Dialog.Root>
