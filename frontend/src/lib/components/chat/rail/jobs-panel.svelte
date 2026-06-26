<script lang="ts">
	import { onMount } from 'svelte';
	import { Pause, Play, Square } from '@lucide/svelte';
	import {
		conversationJobs,
		pauseJob,
		resumeJob,
		stopJob,
		type JobEntry,
		type RpcResult
	} from '$lib/ash/api';
	import { relativeTime } from '$lib/time';

	let { conversationId }: { conversationId: string } = $props();

	let jobs = $state<JobEntry[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);

	onMount(() => {
		void refresh();
	});

	async function refresh() {
		const result = await conversationJobs(conversationId);
		if (result.success) jobs = result.data;
		loading = false;
	}

	async function act(action: (id: string) => Promise<RpcResult<JobEntry>>, job: JobEntry) {
		error = null;
		const result = await action(job.id);
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Job action failed';
			return;
		}
		// stop drops the job from the non-stopped listing; pause/resume update it
		if (result.data.status === 'stopped') {
			jobs = jobs.filter((entry) => entry.id !== job.id);
		} else {
			jobs = jobs.map((entry) => (entry.id === job.id ? result.data : entry));
		}
	}

	function scheduleLabel(job: JobEntry): string {
		if (job.scheduleType === 'cron' && job.cronExpressionLocal) return job.cronExpressionLocal;
		if (job.scheduledAt) return `once, ${relativeTime(job.scheduledAt)}`;
		return job.scheduleType;
	}
</script>

<div class="flex min-h-0 flex-1 flex-col" data-testid="rail-jobs-panel">
	<p class="border-b p-2.5 text-xs font-medium">Active jobs</p>
	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto p-1.5">
		{#if error}
			<p class="p-2 text-xs text-destructive">{error}</p>
		{/if}
		{#if loading}
			<div class="space-y-2 p-1">
				{#each [1, 2] as i (i)}
					<div class="h-10 animate-pulse rounded-md bg-muted"></div>
				{/each}
			</div>
		{:else if jobs.length === 0}
			<p class="p-2 text-xs text-muted-foreground">No active jobs.</p>
		{:else}
			<ul class="space-y-0.5">
				{#each jobs as job (job.id)}
					<li class="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-accent/60">
						<span class="min-w-0 flex-1">
							<span class="block truncate text-xs font-medium">{job.name}</span>
							<span class="block text-[11px] text-muted-foreground">
								{job.status} · {scheduleLabel(job)}
								{#if job.nextRunAt}
									· next {relativeTime(job.nextRunAt)}
								{/if}
							</span>
						</span>
						{#if job.status === 'active'}
							<button
								type="button"
								class="shrink-0 rounded-md p-1 text-muted-foreground transition-colors hover:text-foreground"
								title="Pause"
								data-testid="rail-pause-job"
								onclick={() => void act(pauseJob, job)}
							>
								<Pause class="size-3.5" />
							</button>
						{:else if job.status === 'paused'}
							<button
								type="button"
								class="shrink-0 rounded-md p-1 text-muted-foreground transition-colors hover:text-foreground"
								title="Resume"
								data-testid="rail-resume-job"
								onclick={() => void act(resumeJob, job)}
							>
								<Play class="size-3.5" />
							</button>
						{/if}
						<button
							type="button"
							class="shrink-0 rounded-md p-1 text-muted-foreground transition-colors hover:text-destructive"
							title="Stop"
							data-testid="rail-stop-job"
							onclick={() => void act(stopJob, job)}
						>
							<Square class="size-3.5" />
						</button>
					</li>
				{/each}
			</ul>
		{/if}
	</div>
</div>
