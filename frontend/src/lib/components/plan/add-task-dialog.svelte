<script lang="ts">
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button, Field, CONTROL_CLASS, TEXTAREA_CLASS } from '$lib/components/crud';
	import type { TaskBoardStore } from './task-board-store.svelte';
	import type { TaskPriority } from '$lib/ash/api';

	let {
		open = $bindable(false),
		store
	}: {
		open?: boolean;
		store: TaskBoardStore;
	} = $props();

	let title = $state('');
	let description = $state('');
	let priority = $state<TaskPriority>('normal');
	let dueDate = $state(''); // yyyy-mm-dd from <input type="date">
	let saving = $state(false);
	let error = $state<string | null>(null);

	const PRIORITIES: { value: TaskPriority; label: string }[] = [
		{ value: 'urgent', label: 'Urgent' },
		{ value: 'high', label: 'High' },
		{ value: 'normal', label: 'Normal' },
		{ value: 'low', label: 'Low' }
	];

	// Reset the form each time the dialog opens.
	$effect(() => {
		if (!open) return;
		title = '';
		description = '';
		priority = 'normal';
		dueDate = '';
		saving = false;
		error = null;
	});

	const canSave = $derived(title.trim() !== '' && !saving);

	async function save() {
		if (saving || title.trim() === '') return;
		saving = true;
		error = null;
		// A date-only value becomes UTC midnight of that day.
		const dueAt = dueDate ? new Date(dueDate).toISOString() : null;
		const ok = await store.createTask({ title, description, priority, dueAt });
		saving = false;
		if (ok) open = false;
		else error = 'Task could not be created. Please try again.';
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-lg" data-testid="add-task-dialog">
		<Dialog.Header>
			<Dialog.Title>Add task</Dialog.Title>
			<Dialog.Description>Add a task to this plan. Only a title is required.</Dialog.Description>
		</Dialog.Header>

		<form
			class="flex flex-col gap-4"
			onsubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<Field label="Title" required>
				<!-- svelte-ignore a11y_autofocus — single-purpose dialog -->
				<input
					bind:value={title}
					autofocus
					required
					placeholder="What needs doing?"
					class={CONTROL_CLASS}
					data-testid="add-task-title"
				/>
			</Field>

			<Field label="Description">
				<textarea
					bind:value={description}
					rows="4"
					placeholder="Optional details…"
					class={TEXTAREA_CLASS}
					data-testid="add-task-description"
				></textarea>
			</Field>

			<div class="flex flex-col gap-4 sm:flex-row sm:gap-3">
				<div class="sm:flex-1">
					<Field label="Priority">
						<select bind:value={priority} class={CONTROL_CLASS} data-testid="add-task-priority">
							{#each PRIORITIES as p (p.value)}
								<option value={p.value}>{p.label}</option>
							{/each}
						</select>
					</Field>
				</div>
				<div class="sm:flex-1">
					<Field label="Due date">
						<input
							type="date"
							bind:value={dueDate}
							class={CONTROL_CLASS}
							data-testid="add-task-due"
						/>
					</Field>
				</div>
			</div>

			{#if error}
				<p class="text-xs text-destructive" data-testid="add-task-error">{error}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
				<Button type="submit" disabled={!canSave} data-testid="add-task-save">
					{saving ? 'Adding…' : 'Add task'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
