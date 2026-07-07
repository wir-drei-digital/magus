<script lang="ts">
	/**
	 * Read-only list of a brain's defined types (its `:template` pages, see
	 * `Magus.Brain.Guide`'s types index). Shows the agent-visible name +
	 * description for each type so a viewer can see what shapes this brain's
	 * content into without opening the tool output. Editing templates stays
	 * in the agent's `define_type` tool / the page editor for now.
	 */
	import { Shapes } from '@lucide/svelte';
	import { templatesForBrain, type TypeEntry } from '$lib/ash/api';

	let { brainId }: { brainId: string } = $props();

	let types = $state<TypeEntry[]>([]);
	let loading = $state(true);

	$effect(() => {
		const id = brainId;
		loading = true;
		void templatesForBrain(id).then((result) => {
			if (id !== brainId) return;
			if (result.success) types = result.data;
			loading = false;
		});
	});
</script>

<div class="flex flex-col gap-2" data-testid="types-view">
	<div class="flex items-center gap-2 px-1">
		<Shapes class="size-4 shrink-0 text-primary-link" />
		<span class="text-sm font-semibold text-foreground">Types</span>
		<span class="text-xs text-muted-foreground tabular-nums" data-testid="types-view-count">
			{types.length}
		</span>
	</div>

	{#if loading}
		<p class="px-1 text-xs text-muted-foreground">Loading…</p>
	{:else if types.length === 0}
		<p class="px-1 text-xs text-muted-foreground" data-testid="types-view-empty">
			No types defined yet. The agent proposes types as it organizes this brain's content.
		</p>
	{:else}
		<ul class="flex flex-col gap-1.5" data-testid="types-view-list">
			{#each types as type (type.id)}
				<li class="rounded-md border px-2.5 py-1.5">
					<p class="text-sm font-medium">{type.title}</p>
					{#if type.description}
						<p class="truncate text-xs text-muted-foreground">{type.description}</p>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
</div>
