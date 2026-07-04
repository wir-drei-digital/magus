<script lang="ts">
	import { Check, TriangleAlert, GripVertical, ListChecks } from '@lucide/svelte';
	import type { PlanTask } from '$lib/ash/api';
	import { relativeTime } from '$lib/time';
	import PriorityBadge from './priority-badge.svelte';
	import ReadyBadge from './ready-badge.svelte';
	import AssigneeChip from './assignee-chip.svelte';
	import {
		isReady,
		isStale,
		leaseExpiresInMinutes,
		type PlanBoardStore
	} from './plan-board-store.svelte';

	let {
		task,
		store,
		ondragstart
	}: {
		task: PlanTask;
		store: PlanBoardStore;
		ondragstart?: (event: DragEvent, task: PlanTask) => void;
	} = $props();

	const ready = $derived(isReady(task));
	const stale = $derived(isStale(task));
	const expiresInMinutes = $derived(leaseExpiresInMinutes(task));
	const assignee = $derived(store.resolveAssignee(task));
	const busy = $derived(store.pending.has(task.id));
	const blocked = $derived(task.status === 'blocked' || task.status === 'cancelled');
	const claimedLabel = $derived(task.claimedAt ?? null);

	// State is carried by PriorityBadge + ReadyBadge + the status dot, so the card
	// keeps a single calm full border (no colored side-stripe accent).
</script>

<div
	data-testid="task-card"
	data-status={task.status}
	data-ready={ready ? 'true' : 'false'}
	data-stale={stale ? 'true' : undefined}
	draggable={!blocked}
	ondragstart={(event) => ondragstart?.(event, task)}
	role="listitem"
	class="group/card relative flex flex-col gap-2 rounded-lg border bg-card/60 p-2.5 shadow-sm transition-colors hover:border-border hover:bg-card"
>
	<!-- Top row: priority + ready pip on the left; deps note on the right. -->
	<div class="flex items-center gap-1.5">
		{#if blocked}
			<ReadyBadge variant="blocked" />
		{:else}
			<PriorityBadge priority={task.priority} />
			{#if ready}
				<ReadyBadge variant="ready" />
			{/if}
		{/if}
		<span class="ml-auto shrink-0 text-[10px] text-muted-foreground">
			{#if task.openDependenciesCount > 0}
				<span data-testid="task-blocks" title="Unfinished tasks this task depends on">
					blocked by {task.openDependenciesCount}
				</span>
			{:else if task.status === 'open' && task.openDependenciesCount === 0 && !ready}
				deps clear
			{:else if ready}
				↳ deps clear
			{/if}
		</span>
	</div>

	<!-- Title -->
	<p class="text-sm leading-snug font-medium text-foreground">
		{task.title}
	</p>

	{#if blocked}
		{#if task.resultSummary}
			<p class="text-xs text-muted-foreground">↳ {task.resultSummary}</p>
		{/if}
	{:else if ready || (task.status === 'open' && assignee === null)}
		<!-- Ready / open + unassigned: the claim affordance. -->
		<div class="flex items-center justify-between gap-2">
			<span class="text-[11px] text-muted-foreground italic">unassigned</span>
			<button
				type="button"
				data-testid="task-claim"
				disabled={busy}
				onclick={() => void store.claim(task)}
				class="inline-flex items-center gap-1 rounded-md border border-dashed border-success/50 px-2 py-1 text-xs font-medium text-success transition-colors hover:border-success hover:bg-success/10 disabled:opacity-50"
			>
				<Check class="size-3.5" /> Claim
			</button>
		</div>
	{:else if task.status === 'in_progress'}
		<!-- In progress: real subtask progress (completed / total), stale banner,
		     assignee + timestamp. The bar reflects completedSubtaskCount/subtaskCount. -->
		{#if task.subtaskCount > 0}
			<div class="flex flex-col gap-1" data-testid="task-subtasks">
				<div class="flex items-center gap-1.5">
					<ListChecks class="size-3 shrink-0 text-muted-foreground" />
					<span class="text-[10px] tabular-nums text-muted-foreground">
						{task.completedSubtaskCount}/{task.subtaskCount} subtask{task.subtaskCount === 1
							? ''
							: 's'}
					</span>
				</div>
				<div
					class="h-1 overflow-hidden rounded-full bg-secondary"
					role="presentation"
					data-testid="task-subtask-progress"
				>
					<div
						class="h-full bg-success transition-all"
						style="width: {(task.completedSubtaskCount / task.subtaskCount) * 100}%"
					></div>
				</div>
			</div>
		{/if}

		{#if stale}
			<div
				data-testid="task-stale"
				class="flex items-center gap-1.5 rounded-md bg-warning/10 px-2 py-1 text-[11px] text-warning"
			>
				<TriangleAlert class="size-3 shrink-0" />
				<span>Lease expired, reclaiming</span>
			</div>
		{/if}

		<div class="flex items-center justify-between gap-2 pt-0.5">
			{#if assignee}
				<AssigneeChip {assignee} class="min-w-0" />
			{:else}
				<span></span>
			{/if}
			{#if !stale && expiresInMinutes !== null}
				<span class="shrink-0 text-[10px] text-muted-foreground"
					>expires in {expiresInMinutes}m</span
				>
			{:else if claimedLabel}
				<span class="shrink-0 text-[10px] text-muted-foreground">{relativeTime(claimedLabel)}</span>
			{/if}
		</div>
	{:else if task.status === 'done'}
		<div class="flex items-center justify-between gap-2 pt-0.5">
			{#if assignee}
				<AssigneeChip {assignee} class="min-w-0" />
			{:else}
				<span class="text-[11px] text-muted-foreground">Completed</span>
			{/if}
			<span class="inline-flex shrink-0 items-center gap-1 text-[10px] text-success">
				<Check class="size-3" /> done
			</span>
		</div>
	{/if}

	<!-- Drag handle: a subtle affordance revealed on hover (cards are draggable). -->
	{#if !blocked}
		<span
			class="pointer-events-none absolute -top-1 right-1 text-muted-foreground/0 transition-colors group-hover/card:text-muted-foreground/40"
			aria-hidden="true"
		>
			<GripVertical class="size-3.5" />
		</span>
	{/if}
</div>
