<script lang="ts">
	import { Check, Plus, Trash2 } from '@lucide/svelte';
	import {
		conversationTasks,
		createConversationTask,
		destroyConversationTask,
		updateConversationTask,
		type ConversationTask,
		type TaskStatus
	} from '$lib/ash/api';

	let { conversationId }: { conversationId: string } = $props();

	let tasks = $state<ConversationTask[]>([]);
	let loading = $state(true);
	let newTitle = $state('');
	let editingId = $state<string | null>(null);
	let editValue = $state('');

	const STATUSES: { value: TaskStatus; label: string }[] = [
		{ value: 'open', label: 'Open' },
		{ value: 'in_progress', label: 'In progress' },
		{ value: 'blocked', label: 'Blocked' },
		{ value: 'done', label: 'Done' },
		{ value: 'cancelled', label: 'Cancelled' }
	];

	const active = $derived(tasks.filter((t) => t.status !== 'done' && t.status !== 'cancelled'));
	const finished = $derived(tasks.filter((t) => t.status === 'done' || t.status === 'cancelled'));

	$effect(() => {
		const id = conversationId;
		loading = true;
		void conversationTasks(id).then((result) => {
			if (id !== conversationId) return;
			if (result.success) tasks = result.data;
			loading = false;
		});
	});

	function upsert(task: ConversationTask) {
		const index = tasks.findIndex((t) => t.id === task.id);
		tasks = index >= 0 ? tasks.map((t) => (t.id === task.id ? task : t)) : [...tasks, task];
	}

	async function addTask() {
		const title = newTitle.trim();
		if (!title) return;
		newTitle = '';
		const result = await createConversationTask(conversationId, { title });
		if (result.success) upsert(result.data);
	}

	async function setStatus(task: ConversationTask, status: TaskStatus) {
		// Optimistic; reconcile from the server row.
		upsert({ ...task, status });
		const result = await updateConversationTask(task.id, { status });
		if (result.success) upsert(result.data);
	}

	function toggleDone(task: ConversationTask) {
		void setStatus(task, task.status === 'done' ? 'open' : 'done');
	}

	async function saveTitle(task: ConversationTask) {
		const title = editValue.trim();
		editingId = null;
		if (!title || title === task.title) return;
		upsert({ ...task, title });
		const result = await updateConversationTask(task.id, { title });
		if (result.success) upsert(result.data);
	}

	async function remove(task: ConversationTask) {
		tasks = tasks.filter((t) => t.id !== task.id);
		await destroyConversationTask(task.id);
	}
</script>

<div class="flex min-h-0 flex-1 flex-col overflow-y-auto" data-testid="tasks-list">
	<div class="flex items-center gap-2 border-b p-2">
		<input
			bind:value={newTitle}
			placeholder="Add a task…"
			class="min-w-0 flex-1 rounded-md border border-input bg-secondary px-3 py-1.5 text-sm outline-none focus:border-primary/60"
			onkeydown={(event) => {
				if (event.key === 'Enter') void addTask();
			}}
		/>
		<button
			type="button"
			class="wb-pill-btn gap-1 text-xs"
			disabled={newTitle.trim() === ''}
			onclick={() => void addTask()}
			data-testid="task-add"
		>
			<Plus class="size-3.5" /> Add
		</button>
	</div>

	{#if loading}
		<p class="p-4 text-sm text-muted-foreground">Loading tasks…</p>
	{:else if tasks.length === 0}
		<p class="p-4 text-sm text-muted-foreground">No tasks yet. Add one above.</p>
	{:else}
		<div class="flex flex-col">
			{#each active as task (task.id)}
				{@render row(task)}
			{/each}
			{#if finished.length > 0}
				<p class="px-3 pt-3 pb-1 text-xs tracking-wider text-muted-foreground uppercase">Done</p>
				{#each finished as task (task.id)}
					{@render row(task)}
				{/each}
			{/if}
		</div>
	{/if}
</div>

{#snippet row(task: ConversationTask)}
	<div class="group flex items-center gap-2 border-b px-3 py-2 text-sm" data-testid="task-row">
		<button
			type="button"
			class="flex size-4 shrink-0 items-center justify-center rounded border {task.status === 'done'
				? 'border-success bg-success text-primary-foreground'
				: 'border-input'}"
			aria-label={task.status === 'done' ? 'Reopen task' : 'Mark done'}
			data-testid="task-toggle"
			onclick={() => toggleDone(task)}
		>
			{#if task.status === 'done'}<Check class="size-3" />{/if}
		</button>

		{#if editingId === task.id}
			<input
				bind:value={editValue}
				class="min-w-0 flex-1 rounded border border-input bg-secondary px-2 py-1 text-sm outline-none"
				onblur={() => void saveTitle(task)}
				onkeydown={(event) => {
					if (event.key === 'Enter') void saveTitle(task);
					if (event.key === 'Escape') editingId = null;
				}}
			/>
		{:else}
			<button
				type="button"
				class="min-w-0 flex-1 truncate text-left {task.status === 'done' ||
				task.status === 'cancelled'
					? 'text-muted-foreground line-through'
					: ''}"
				onclick={() => {
					editingId = task.id;
					editValue = task.title;
				}}
			>
				{task.title}
			</button>
		{/if}

		<select
			value={task.status}
			class="shrink-0 rounded border border-input bg-secondary px-1.5 py-0.5 text-xs"
			onchange={(event) => void setStatus(task, event.currentTarget.value as TaskStatus)}
		>
			{#each STATUSES as status (status.value)}
				<option value={status.value}>{status.label}</option>
			{/each}
		</select>

		<button
			type="button"
			class="shrink-0 rounded p-1 text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 hover:text-destructive"
			aria-label="Delete task"
			data-testid="task-delete"
			onclick={() => void remove(task)}
		>
			<Trash2 class="size-3.5" />
		</button>
	</div>
{/snippet}
