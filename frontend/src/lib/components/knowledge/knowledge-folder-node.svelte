<script lang="ts">
	import { ChevronDown, ChevronRight, Folder, Loader2 } from '@lucide/svelte';
	import { knowledgeSourceFolders, type KnowledgeFolderNode } from '$lib/ash/api';
	import type { SvelteMap } from 'svelte/reactivity';
	import Self from './knowledge-folder-node.svelte';

	let {
		sourceId,
		node,
		level = 0,
		selected,
		onToggle
	}: {
		sourceId: string;
		node: KnowledgeFolderNode;
		level?: number;
		/** id -> folder, shared across the tree; reactive so checkboxes update. */
		selected: SvelteMap<string, KnowledgeFolderNode>;
		onToggle: (node: KnowledgeFolderNode, checked: boolean) => void;
	} = $props();

	let expanded = $state(false);
	let loaded = $state(false);
	let loading = $state(false);
	let children = $state<KnowledgeFolderNode[]>([]);
	let error = $state<string | null>(null);

	async function toggleExpand() {
		expanded = !expanded;
		if (!expanded || loaded || loading) return;
		loading = true;
		const result = await knowledgeSourceFolders(sourceId, node.id);
		loading = false;
		loaded = true;
		if (result.success) children = result.data;
		else error = result.errors[0]?.message ?? 'Could not load folders';
	}

	const indent = $derived(level * 16 + 4);
</script>

<div>
	<div
		class="flex items-center gap-1.5 rounded-md py-1 hover:bg-accent/50"
		style="padding-left: {indent}px"
	>
		<button
			type="button"
			class="flex size-4 shrink-0 items-center justify-center text-muted-foreground"
			onclick={toggleExpand}
			aria-label={expanded ? 'Collapse' : 'Expand'}
		>
			{#if loading}
				<Loader2 class="size-3.5 animate-spin" />
			{:else if expanded}
				<ChevronDown class="size-3.5" />
			{:else}
				<ChevronRight class="size-3.5" />
			{/if}
		</button>
		<label class="flex min-w-0 flex-1 items-center gap-2 text-sm">
			<input
				type="checkbox"
				class="shrink-0"
				checked={selected.has(node.id)}
				onchange={(event) => onToggle(node, event.currentTarget.checked)}
				data-testid="knowledge-folder-checkbox"
			/>
			<Folder class="size-3.5 shrink-0 text-muted-foreground" />
			<span class="truncate">{node.name}</span>
		</label>
	</div>

	{#if expanded}
		{#if error}
			<p class="text-xs text-destructive" style="padding-left: {indent + 24}px">{error}</p>
		{:else if loaded && children.length === 0}
			<p class="text-xs text-muted-foreground" style="padding-left: {indent + 24}px">
				No subfolders
			</p>
		{/if}
		{#each children as child (child.id)}
			<Self {sourceId} node={child} level={level + 1} {selected} {onToggle} />
		{/each}
	{/if}
</div>
