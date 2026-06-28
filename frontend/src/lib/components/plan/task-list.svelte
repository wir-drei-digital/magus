<script lang="ts">
	import {
		Check,
		ChevronDown,
		ChevronRight,
		GripVertical,
		ListChecks,
		Plus,
		TriangleAlert
	} from '@lucide/svelte';
	import type { PlanTask } from '$lib/ash/api';
	import { relativeTime } from '$lib/time';
	import PriorityBadge from './priority-badge.svelte';
	import ReadyBadge from './ready-badge.svelte';
	import AssigneeChip from './assignee-chip.svelte';
	import { isReady, isStale, type PlanBoardStore } from './plan-board-store.svelte';

	let { store }: { store: PlanBoardStore } = $props();

	let newTitle = $state('');
	let adding = $state(false);

	// Done collapses by default (the design's "✓ Done · collapsed").
	let collapsed = $state<Record<string, boolean>>({ done: true });

	function toggle(key: string) {
		collapsed = { ...collapsed, [key]: !collapsed[key] };
	}

	async function add() {
		const title = newTitle.trim();
		if (!title || adding) return;
		adding = true;
		newTitle = '';
		await store.addTask(title);
		adding = false;
	}

	// Status dot color per row, tokenized.
	function statusDot(task: PlanTask): string {
		if (task.status === 'in_progress') return 'bg-primary';
		if (task.status === 'done') return 'bg-success/60';
		if (task.status === 'blocked' || task.status === 'cancelled') return 'bg-warning';
		return isReady(task) ? 'bg-success' : 'bg-muted-foreground/40';
	}

	type Group = {
		key: string;
		label: string;
		dot: string;
		tasks: PlanTask[];
		subBadge?: string;
		lock?: boolean;
	};

	const groups = $derived<Group[]>([
		{
			key: 'in_progress',
			label: 'In Progress',
			dot: 'bg-primary',
			tasks: store.inProgress
		},
		{
			key: 'ready',
			label: 'Ready',
			dot: 'bg-success',
			tasks: store.ready,
			subBadge: 'unassigned · deps clear · grabbable'
		},
		{
			key: 'blocked',
			label: 'Blocked',
			dot: 'bg-warning',
			tasks: store.blockedLane,
			lock: true
		},
		{
			key: 'done',
			label: 'Done',
			dot: 'bg-success/60',
			tasks: store.done
		}
	]);
</script>

<div class="flex flex-col" data-testid="task-list-view">
	<!-- Add task row -->
	<div class="flex items-center gap-2 border-b px-3 py-2">
		<Plus class="size-4 shrink-0 text-muted-foreground" />
		<input
			bind:value={newTitle}
			placeholder="Add task…"
			data-testid="task-add-input"
			class="min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
			onkeydown={(event) => {
				if (event.key === 'Enter') void add();
			}}
		/>
		{#if newTitle.trim()}
			<button
				type="button"
				class="wb-pill-btn shrink-0 text-xs"
				data-testid="task-add"
				disabled={adding}
				onclick={() => void add()}
			>
				Add
			</button>
		{/if}
	</div>

	{#each groups as group (group.key)}
		{#if group.tasks.length > 0}
			<div data-testid="task-group" data-group={group.key}>
				<!-- Group header -->
				<button
					type="button"
					class="flex w-full items-center gap-2 px-3 py-1.5 text-left transition-colors hover:bg-accent/40"
					onclick={() => toggle(group.key)}
				>
					{#if collapsed[group.key]}
						<ChevronRight class="size-3.5 shrink-0 text-muted-foreground" />
					{:else}
						<ChevronDown class="size-3.5 shrink-0 text-muted-foreground" />
					{/if}
					<span class="size-1.5 shrink-0 rounded-full {group.dot}"></span>
					<span class="text-xs font-semibold text-foreground">{group.label}</span>
					<span class="text-xs text-muted-foreground tabular-nums">{group.tasks.length}</span>
					{#if group.subBadge}
						<span class="ml-1 truncate text-[10px] text-muted-foreground italic">
							{group.subBadge}
						</span>
					{/if}
				</button>

				<!-- Rows -->
				{#if !collapsed[group.key]}
					{#each group.tasks as task (task.id)}
						{@render row(task)}
					{/each}
				{/if}
			</div>
		{/if}
	{/each}
</div>

{#snippet row(task: PlanTask)}
	{@const ready = isReady(task)}
	{@const stale = isStale(task)}
	{@const assignee = store.resolveAssignee(task)}
	{@const busy = store.pending.has(task.id)}
	<div
		data-testid="task-row"
		data-status={task.status}
		data-ready={ready ? 'true' : 'false'}
		class="group/row flex items-center gap-2 border-b px-3 py-2 transition-colors hover:bg-accent/30"
	>
		<span
			class="shrink-0 text-muted-foreground/0 transition-colors group-hover/row:text-muted-foreground/40"
			aria-hidden="true"
		>
			<GripVertical class="size-3.5" />
		</span>
		<span class="size-2 shrink-0 rounded-full {statusDot(task)}"></span>
		<PriorityBadge priority={task.priority} class="shrink-0" />
		<span class="min-w-0 flex-1 truncate text-sm text-foreground">{task.title}</span>

		{#if stale}
			<span
				class="shrink-0 text-warning"
				data-testid="task-stale"
				title="Lease expired, reclaiming"
			>
				<TriangleAlert class="size-3.5" />
			</span>
		{/if}

		{#if task.subtaskCount > 0}
			<span
				class="inline-flex shrink-0 items-center gap-1 text-[10px] tabular-nums text-muted-foreground"
				data-testid="task-subtasks"
			>
				<ListChecks class="size-3" />
				{task.subtaskCount}
			</span>
		{/if}

		{#if task.openDependenciesCount > 0}
			<span
				class="shrink-0 text-[10px] text-muted-foreground"
				data-testid="task-blocks"
				title="Blocked by {task.openDependenciesCount} unfinished dependenc{task.openDependenciesCount ===
				1
					? 'y'
					: 'ies'}"
			>
				↳ {task.openDependenciesCount}
			</span>
		{/if}

		{#if ready}
			<ReadyBadge variant="ready" class="shrink-0" />
			<button
				type="button"
				data-testid="task-claim"
				disabled={busy}
				onclick={() => void store.claim(task)}
				class="inline-flex shrink-0 items-center gap-1 rounded-md border border-dashed border-success/50 px-2 py-0.5 text-xs font-medium text-success transition-colors hover:border-success hover:bg-success/10 disabled:opacity-50"
			>
				<Check class="size-3" /> Claim
			</button>
		{:else if assignee}
			<AssigneeChip {assignee} class="max-w-[8rem] shrink-0" />
		{/if}

		{#if task.claimedAt}
			<span class="w-14 shrink-0 text-right text-[10px] text-muted-foreground">
				{relativeTime(task.claimedAt)}
			</span>
		{/if}
	</div>
{/snippet}
