<script lang="ts">
	/**
	 * Collapsible dock for the task board, present under every content brain
	 * page. A thin view over {@link TaskBottomBarStore}: this component only
	 * renders the compact header (count + chevron) and toggles the body: all
	 * collapse/persistence logic lives in the store so it's unit-testable
	 * without mounting Svelte.
	 *
	 * The count shown here (and fed to the store's collapsed-by-default calc)
	 * comes from a small dedicated load, independent of the `TaskBoard` body's
	 * own internal `TaskBoardStore`: `TaskBoard` is used as-is and doesn't
	 * expose its task list outward.
	 */
	import { ChevronDown, ChevronUp, SquareKanban } from '@lucide/svelte';
	import { untrack } from 'svelte';
	import { planTasks } from '$lib/ash/api';
	import TaskBoard from '$lib/components/plan/task-board.svelte';
	import { TaskBottomBarStore } from './task-bottom-bar-store.svelte';

	let { brainId, brainPageId }: { brainId: string; brainPageId: string } = $props();

	let taskCount = $state(0);
	let store = $state(untrack(() => new TaskBottomBarStore(brainId, () => taskCount)));

	let mounted = false;
	$effect(() => {
		const id = brainPageId;
		// Skip the first run: `store` above already seeded for the initial
		// brainId; re-creating here would discard the just-computed default.
		if (!mounted) {
			mounted = true;
		} else {
			store = new TaskBottomBarStore(brainId, () => taskCount);
		}
		void planTasks(id).then((result) => {
			if (id === brainPageId && result.success) {
				taskCount = result.data.filter((t) => t.status !== 'archived').length;
			}
		});
	});
</script>

<div class="flex shrink-0 flex-col border-t bg-background" data-testid="task-bottom-bar">
	<div class="flex items-center gap-2 px-4 py-2">
		<SquareKanban class="size-4 shrink-0 text-primary-link" />
		<span class="text-sm font-semibold text-foreground">Tasks</span>
		<span class="text-xs text-muted-foreground tabular-nums" data-testid="task-bottom-bar-count">
			{taskCount}
		</span>
		<span class="flex-1"></span>
		<button
			type="button"
			class="rounded p-1 text-muted-foreground hover:text-foreground"
			data-testid="task-bottom-bar-toggle"
			aria-label={store.collapsed ? 'Expand tasks' : 'Collapse tasks'}
			aria-expanded={!store.collapsed}
			onclick={() => store.toggle()}
		>
			{#if store.collapsed}
				<ChevronUp class="size-3.5" />
			{:else}
				<ChevronDown class="size-3.5" />
			{/if}
		</button>
	</div>

	{#if !store.collapsed}
		<div class="flex max-h-[55%] min-h-0 flex-col">
			<TaskBoard {brainPageId} />
		</div>
	{/if}
</div>
