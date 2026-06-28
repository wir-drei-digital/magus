<script lang="ts" module>
	import type { TaskEventKind } from '$lib/ash/api';

	// Event kind → feed dot color. Creation is neutral-primary, claims info-blue,
	// completion success-green, releases/reassigns muted, lease reclaim amber.
	const KIND_DOT: Record<TaskEventKind, string> = {
		created: 'bg-primary',
		claimed: 'bg-info',
		released: 'bg-muted-foreground/50',
		status_changed: 'bg-info/70',
		completed: 'bg-success',
		reassigned: 'bg-favorite',
		lease_expired: 'bg-warning'
	};
</script>

<script lang="ts">
	import { base } from '$app/paths';
	import { Activity } from '@lucide/svelte';
	import { relativeTime } from '$lib/time';
	import type { ActivityEntry } from './brain-overview-store.svelte';

	let { entries }: { entries: ActivityEntry[] } = $props();
</script>

<section data-testid="overview-activity" class="flex min-h-0 flex-col">
	<header class="flex items-center gap-2 px-1 pb-2">
		<Activity class="size-4 shrink-0 text-primary-link" />
		<h2 class="text-sm font-semibold text-foreground">Activity</h2>
		<span class="flex items-center gap-1 text-[11px] font-medium text-success">
			<span class="size-1.5 animate-pulse rounded-full bg-success"></span>
			live feed
		</span>
	</header>

	{#if entries.length === 0}
		<p class="px-1 py-6 text-sm text-muted-foreground">No activity yet.</p>
	{:else}
		<ol class="relative flex min-h-0 flex-col gap-0 overflow-y-auto">
			{#each entries as entry, i (entry.id)}
				<li class="flex gap-2.5 py-2" data-testid="activity-entry" data-kind={entry.kind}>
					<!-- Dot + connector rail (the rail stops at the last entry). -->
					<div class="flex shrink-0 flex-col items-center pt-1">
						<span class="size-2 rounded-full {KIND_DOT[entry.kind]}"></span>
						{#if i < entries.length - 1}
							<span class="mt-1 w-px flex-1 bg-border/70"></span>
						{/if}
					</div>

					<div class="flex min-w-0 flex-1 flex-col gap-0.5 pb-1">
						<p class="text-[13px] leading-snug text-secondary-foreground">
							<span class="font-semibold text-foreground">
								{entry.isSelf ? 'You' : entry.actorLabel}
							</span>
							{entry.verb}
							{#if entry.taskTitle}
								<a
									href="{base}/brain/page/{entry.brainPageId}"
									class="font-medium text-foreground hover:underline"
								>
									{entry.taskTitle}
								</a>
							{:else}
								<span class="text-muted-foreground italic">a task</span>
							{/if}
						</p>
						<p class="flex items-center gap-1.5 text-[11px] text-muted-foreground">
							<span class="truncate">{entry.planTitle}</span>
							<span aria-hidden="true">·</span>
							<span class="shrink-0 tabular-nums">{relativeTime(entry.insertedAt)}</span>
						</p>
					</div>
				</li>
			{/each}
		</ol>
	{/if}
</section>
