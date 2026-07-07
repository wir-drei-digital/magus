<script lang="ts">
	import { Columns3, LayoutList, SquareKanban, Zap, Lock, Plus } from '@lucide/svelte';
	import type { PlanTask } from '$lib/ash/api';
	import TaskCard from './task-card.svelte';
	import TaskList from './task-list.svelte';
	import AddTaskDialog from './add-task-dialog.svelte';
	import { untrack } from 'svelte';
	import {
		TaskBoardStore,
		loadBoardView,
		saveBoardView,
		type BoardView
	} from './task-board-store.svelte';
	import { joinPlanTasks } from '$lib/realtime/task-updates';

	let { brainPageId }: { brainPageId: string } = $props();

	// One store per plan page. Re-created when the id changes so navigating
	// between plan pages reloads cleanly (mirrors the prompts $effect-load).
	// untrack: the initial construction reads the prop for its seed value only;
	// the $effect below owns re-creation + reload when the id actually changes.
	let store = $state(untrack(() => new TaskBoardStore(brainPageId)));
	let view = $state<BoardView>(untrack(() => loadBoardView(brainPageId)));
	let addOpen = $state(false);

	let mounted = false;
	$effect(() => {
		const id = brainPageId;
		// Skip the first run: the initial store/view above already match this id,
		// so re-creating would fire a duplicate load on mount.
		if (!mounted) {
			mounted = true;
			void store.load();
			return;
		}
		store = new TaskBoardStore(id);
		view = loadBoardView(id);
		void store.load();
	});

	// Live updates: other clients' (agents') claims / status changes / creates on
	// THIS plan board. Refetch on any task.* event (simplest correct: sidesteps
	// stale-merge bugs). Re-subscribes when the plan id changes; leaves on unmount.
	$effect(() => {
		const id = brainPageId;
		if (!id) return;

		let cancelled = false;
		let leave: (() => void) | null = null;

		void joinPlanTasks(id, () => {
			if (store.brainPageId === id) void store.load();
		}).then((cleanup) => {
			if (cancelled) cleanup();
			else leave = cleanup;
		});

		return () => {
			cancelled = true;
			leave?.();
		};
	});

	function setView(next: BoardView) {
		view = next;
		saveBoardView(brainPageId, next);
	}

	const counts = $derived(store.counts);
	const progress = $derived(store.progress);

	// Jump-to-ready: switch to list (the ready group leads) and surface the pool.
	function jumpToReady() {
		setView('list');
	}

	// Drag-and-drop between kanban columns → status change.
	let dragId = $state<string | null>(null);
	function onCardDragStart(event: DragEvent, task: PlanTask) {
		dragId = task.id;
		event.dataTransfer?.setData('text/plain', task.id);
		if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move';
	}
	function onColumnDrop(status: 'open' | 'in_progress' | 'done') {
		const id = dragId;
		dragId = null;
		if (!id) return;
		const task = store.tasks.find((t) => t.id === id);
		if (task) void store.setStatus(task, status);
	}

	type Column = {
		key: string;
		label: string;
		status: 'open' | 'in_progress' | 'done';
		tasks: PlanTask[];
	};
	const columns = $derived<Column[]>([
		{ key: 'todo', label: 'To Do', status: 'open', tasks: store.todo },
		{ key: 'in_progress', label: 'In Progress', status: 'in_progress', tasks: store.inProgress },
		{ key: 'done', label: 'Done', status: 'done', tasks: store.done }
	]);
</script>

<section
	data-testid="task-board"
	data-view={view}
	class="flex min-h-0 flex-col border-t bg-background"
>
	<!-- ── Tasks summary bar ─────────────────────────────────────────────── -->
	<div class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b px-4 py-2.5">
		<div class="flex items-center gap-2">
			<SquareKanban class="size-4 shrink-0 text-primary-link" />
			<span class="text-sm font-semibold text-foreground">Tasks</span>
		</div>

		<!-- Dot-separated counts -->
		<div
			class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground"
			data-testid="task-board-counts"
		>
			<span class="inline-flex items-center gap-1.5">
				<span class="size-1.5 rounded-full bg-primary"></span>
				<span class="tabular-nums text-foreground">{counts.inProgress}</span> in progress
			</span>
			<span class="inline-flex items-center gap-1.5">
				<span class="size-1.5 rounded-full bg-success"></span>
				<span class="tabular-nums text-foreground">{counts.ready}</span> ready
			</span>
			<span class="inline-flex items-center gap-1.5">
				<span class="size-1.5 rounded-full bg-success/50"></span>
				<span class="tabular-nums text-foreground">{counts.done}</span> done
			</span>
			<span class="inline-flex items-center gap-1.5">
				<span class="size-1.5 rounded-full bg-warning"></span>
				<span class="tabular-nums text-foreground">{counts.blocked}</span> blocked
			</span>
		</div>

		<!-- Segmented progress bar -->
		<div
			class="flex h-1.5 min-w-[6rem] flex-1 overflow-hidden rounded-full bg-secondary"
			data-testid="task-board-progress"
			role="presentation"
		>
			<div class="h-full bg-primary/70" style="width: {progress.inProgress * 100}%"></div>
			<div class="h-full bg-success" style="width: {progress.ready * 100}%"></div>
			<div class="h-full bg-success/40" style="width: {progress.done * 100}%"></div>
		</div>

		<div class="flex items-center gap-2">
			<!-- Add task -->
			<button
				type="button"
				data-testid="task-board-add-task"
				onclick={() => (addOpen = true)}
				class="inline-flex items-center gap-1.5 rounded-md bg-primary px-2.5 py-1 text-xs font-semibold text-primary-foreground transition-colors hover:bg-primary/90"
			>
				<Plus class="size-3.5" />
				Add task
			</button>

			<!-- Ready work pill -->
			<button
				type="button"
				data-testid="task-board-ready-jump"
				onclick={jumpToReady}
				disabled={counts.ready === 0}
				class="inline-flex items-center gap-1.5 rounded-full bg-success/10 px-2.5 py-1 text-xs font-semibold text-success transition-colors hover:bg-success/20 disabled:opacity-40"
			>
				<Zap class="size-3.5" />
				Ready work
				<span class="tabular-nums">· {counts.ready}</span>
			</button>

			<!-- List | Columns toggle -->
			<div
				class="inline-flex items-center rounded-md border bg-card p-0.5"
				role="tablist"
				aria-label="Board view"
			>
				<button
					type="button"
					role="tab"
					aria-selected={view === 'list'}
					data-testid="task-board-view-list"
					onclick={() => setView('list')}
					class="inline-flex items-center gap-1 rounded px-2 py-1 text-xs font-medium transition-colors {view ===
					'list'
						? 'bg-secondary text-foreground'
						: 'text-muted-foreground hover:text-foreground'}"
				>
					<LayoutList class="size-3.5" /> List
				</button>
				<button
					type="button"
					role="tab"
					aria-selected={view === 'columns'}
					data-testid="task-board-view-columns"
					onclick={() => setView('columns')}
					class="inline-flex items-center gap-1 rounded px-2 py-1 text-xs font-medium transition-colors {view ===
					'columns'
						? 'bg-secondary text-foreground'
						: 'text-muted-foreground hover:text-foreground'}"
				>
					<Columns3 class="size-3.5" /> Columns
				</button>
			</div>
		</div>
	</div>

	<!-- ── Body ──────────────────────────────────────────────────────────── -->
	{#if store.loading}
		<p class="p-6 text-sm text-muted-foreground">Loading tasks…</p>
	{:else if store.loadError}
		<p class="p-6 text-sm text-destructive">{store.loadError}</p>
	{:else if store.active.length === 0}
		<div
			class="flex flex-col items-center justify-center gap-2 px-6 py-12 text-center"
			data-testid="task-board-empty"
		>
			<SquareKanban class="size-8 text-muted-foreground/40" />
			<p class="text-sm font-medium text-foreground">No tasks yet</p>
			<p class="max-w-sm text-xs text-muted-foreground">
				Break this plan into tasks. Ready work can be claimed by you or an agent, then tracked
				across To&nbsp;Do, In&nbsp;Progress, and Done.
			</p>
			<button
				type="button"
				data-testid="task-board-empty-add"
				onclick={() => (addOpen = true)}
				class="mt-1 inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-foreground transition-colors hover:bg-primary/90"
			>
				<Plus class="size-3.5" />
				Add task
			</button>
		</div>
	{:else if view === 'list'}
		<div class="min-h-0 overflow-y-auto">
			<TaskList {store} />
		</div>
	{:else}
		<!-- Kanban -->
		<div class="min-h-0 overflow-x-auto p-3">
			<div class="flex min-w-max items-start gap-3">
				{#each columns as column (column.key)}
					<div
						class="flex w-72 shrink-0 flex-col gap-2"
						data-testid="plan-column"
						data-column={column.key}
						ondragover={(event) => event.preventDefault()}
						ondrop={(event) => {
							event.preventDefault();
							onColumnDrop(column.status);
						}}
						role="list"
					>
						<div class="flex items-center gap-2 px-1">
							<span class="text-xs font-semibold tracking-wide text-foreground uppercase">
								{column.label}
							</span>
							<span class="text-xs text-muted-foreground tabular-nums">{column.tasks.length}</span>
							{#if column.key === 'todo' && store.allTodoReady}
								<span
									class="ml-auto rounded-full bg-success/10 px-1.5 py-0.5 text-[10px] font-medium text-success"
								>
									all ready
								</span>
							{/if}
						</div>

						<div class="flex flex-col gap-2">
							{#each column.tasks as task (task.id)}
								<TaskCard {task} {store} ondragstart={onCardDragStart} />
							{/each}
							{#if column.tasks.length === 0}
								<div
									class="rounded-lg border border-dashed border-border/60 px-3 py-6 text-center text-[11px] text-muted-foreground/70"
								>
									Drop here
								</div>
							{/if}
						</div>
					</div>
				{/each}

				<!-- Blocked · Cancelled lane -->
				{#if store.blockedLane.length > 0}
					<div
						class="flex w-64 shrink-0 flex-col gap-2 rounded-lg bg-card/40 p-2"
						data-testid="plan-column"
						data-column="blocked"
						role="list"
					>
						<div class="flex items-center gap-1.5 px-1">
							<Lock class="size-3 shrink-0 text-warning" />
							<span class="text-xs font-semibold tracking-wide text-warning uppercase">
								Blocked · Cancelled
							</span>
							<span class="text-xs text-muted-foreground tabular-nums">
								{store.blockedLane.length}
							</span>
						</div>
						<div class="flex flex-col gap-2">
							{#each store.blockedLane as task (task.id)}
								<TaskCard {task} {store} />
							{/each}
						</div>
					</div>
				{/if}
			</div>
		</div>
	{/if}
</section>

<AddTaskDialog bind:open={addOpen} {store} />
