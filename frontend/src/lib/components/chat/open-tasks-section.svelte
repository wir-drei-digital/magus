<script lang="ts">
	import { onMount } from 'svelte';
	import { base } from '$app/paths';
	import { X } from '@lucide/svelte';
	import { completeTask, dismissTask, listOpenTasks, type OpenTaskEntry } from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';

	// Classic new-chat "Your open tasks": the actor's open, top-level tasks.
	// Completing resolves the task; dismissing only removes it from this list
	// (the task stays open inside its conversation).
	let tasks = $state<OpenTaskEntry[]>([]);
	let busyId = $state<string | null>(null);

	onMount(() => {
		const userId = session.user?.id;
		if (!userId) return;
		void listOpenTasks(userId).then((result) => {
			if (result.success) tasks = result.data;
		});
	});

	async function act(task: OpenTaskEntry, fn: (id: string) => ReturnType<typeof completeTask>) {
		busyId = task.id;
		const result = await fn(task.id);
		busyId = null;
		if (result.success) tasks = tasks.filter((entry) => entry.id !== task.id);
	}

	function isOverdue(iso: string): boolean {
		return new Date(iso).getTime() < Date.now();
	}

	function formatDue(iso: string): string {
		const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
		const days = Math.round((startOfDay(new Date(iso)) - startOfDay(new Date())) / 86_400_000);
		if (days === 0) return 'Today';
		if (days === 1) return 'Tomorrow';
		if (days === -1) return 'Yesterday';
		return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
	}
</script>

{#if tasks.length > 0}
	<div class="mx-auto mb-6 w-full max-w-2xl" data-testid="open-tasks">
		<h3 class="mb-2 text-sm font-medium text-muted-foreground">Your open tasks</h3>
		<div class="flex flex-col gap-0.5">
			{#each tasks as task (task.id)}
				<div
					class="group flex items-center gap-2 rounded-lg p-2 transition-colors hover:bg-accent/50"
					data-testid="open-task"
				>
					<button
						type="button"
						class="size-4 shrink-0 rounded-full border border-muted-foreground/30 transition-colors hover:border-success hover:bg-success/20 disabled:opacity-50"
						title="Mark done"
						aria-label="Mark done"
						disabled={busyId === task.id}
						onclick={() => void act(task, completeTask)}
					></button>
					<a
						href="{base}/chat/{task.conversationId}"
						class="flex min-w-0 flex-1 items-center justify-between gap-2"
					>
						<span class="truncate text-sm">{task.title}</span>
						{#if task.dueAt}
							<span
								class="ml-2 shrink-0 text-xs {isOverdue(task.dueAt)
									? 'text-destructive'
									: 'text-muted-foreground/60'}"
							>
								{formatDue(task.dueAt)}
							</span>
						{/if}
					</a>
					<button
						type="button"
						class="shrink-0 rounded-md p-1 text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 hover:bg-accent disabled:opacity-50"
						title="Dismiss"
						aria-label="Dismiss"
						disabled={busyId === task.id}
						onclick={() => void act(task, dismissTask)}
					>
						<X class="size-3.5" />
					</button>
				</div>
			{/each}
		</div>
	</div>
{/if}
