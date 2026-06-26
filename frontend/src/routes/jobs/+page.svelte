<script lang="ts">
	import { onMount } from 'svelte';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import {
		Clock,
		ExternalLink,
		Pause,
		Play,
		Zap,
		Square,
		CircleCheck,
		CircleX,
		Loader
	} from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { EmptyState } from '$lib/components/ui/empty-state';
	import {
		jobRuns,
		pauseJob,
		resumeJob,
		stopJob,
		triggerJobNow,
		userJobs,
		type JobDetail,
		type JobRunEntry,
		type RpcResult
	} from '$lib/ash/api';
	import { relativeTime } from '$lib/time';
	import { session } from '$lib/stores/session.svelte';

	type Filter = 'all' | 'active' | 'paused';

	let jobs = $state<JobDetail[]>([]);
	let loading = $state(true);
	let filter = $state<Filter>('all');
	let selectedId = $state<string | null>(null);
	let error = $state<string | null>(null);

	let runs = $state<JobRunEntry[]>([]);
	let runsLoading = $state(false);
	let busy = $state(false);

	const filtered = $derived(filter === 'all' ? jobs : jobs.filter((job) => job.status === filter));
	const selected = $derived(jobs.find((job) => job.id === selectedId) ?? null);

	onMount(() => {
		void load();
	});

	async function load() {
		const userId = session.user?.id;
		if (!userId) {
			loading = false;
			return;
		}
		const result = await userJobs(userId);
		if (result.success) {
			jobs = result.data;
			// Deep-link (?job=) or default to the first job.
			const requested = page.url.searchParams.get('job');
			const initial = requested && jobs.some((j) => j.id === requested) ? requested : jobs[0]?.id;
			if (initial) void select(initial);
		}
		loading = false;
	}

	async function select(id: string) {
		selectedId = id;
		runsLoading = true;
		runs = [];
		const result = await jobRuns(id);
		// Drop stale responses after a fast re-select.
		if (selectedId !== id) return;
		if (result.success) runs = result.data;
		runsLoading = false;
	}

	async function act(action: (id: string) => Promise<RpcResult<JobDetail>>) {
		if (!selected || busy) return;
		busy = true;
		error = null;
		const result = await action(selected.id);
		busy = false;
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Job action failed';
			return;
		}
		const updated = result.data;
		if (updated.status === 'stopped') {
			jobs = jobs.filter((job) => job.id !== updated.id);
			selectedId = jobs[0]?.id ?? null;
			if (selectedId) void select(selectedId);
		} else {
			jobs = jobs.map((job) => (job.id === updated.id ? updated : job));
		}
	}

	async function runNow() {
		await act(triggerJobNow);
		if (selectedId) void select(selectedId);
	}

	function scheduleLabel(job: JobDetail): string {
		if (job.scheduleType === 'cron' && job.cronExpressionLocal) return job.cronExpressionLocal;
		if (job.scheduledAt) return `Once, ${relativeTime(job.scheduledAt)}`;
		return job.scheduleType;
	}

	function runDuration(run: JobRunEntry): string | null {
		if (!run.startedAt || !run.completedAt) return null;
		const ms = new Date(run.completedAt).getTime() - new Date(run.startedAt).getTime();
		if (ms < 1000) return `${ms}ms`;
		return `${(ms / 1000).toFixed(1)}s`;
	}
</script>

<svelte:head>
	<title>Magus — Scheduled jobs</title>
</svelte:head>

<div class="flex h-full min-h-0 flex-col" data-testid="jobs-view">
	<header
		class="flex shrink-0 items-center gap-2 border-b bg-background/80 py-3 pr-6 pl-14 md:pl-6"
	>
		<Clock class="size-4 shrink-0 text-muted-foreground" />
		<h1 class="min-w-0 flex-1 truncate text-base font-semibold">Scheduled jobs</h1>
		<div class="flex shrink-0 items-center gap-1.5">
			{#each ['all', 'active', 'paused'] as const as tab (tab)}
				<button
					type="button"
					class="wb-pill-btn shrink-0 capitalize {filter === tab ? 'wb-pill-btn-active' : ''}"
					data-testid="jobs-filter-{tab}"
					onclick={() => (filter = tab)}
				>
					{tab}
				</button>
			{/each}
		</div>
	</header>

	<div class="flex min-h-0 flex-1">
		<!-- List pane -->
		<div class="wb-scroll w-80 shrink-0 overflow-y-auto border-r p-2" data-testid="jobs-list">
			{#if loading}
				<div class="space-y-2 p-1">
					{#each [1, 2, 3] as i (i)}
						<div class="h-12 animate-pulse rounded-lg bg-muted/60"></div>
					{/each}
				</div>
			{:else if filtered.length === 0}
				<EmptyState
					class="h-auto px-3 py-10"
					title={filter === 'all' ? 'No scheduled jobs' : `No ${filter} jobs`}
					description={filter === 'all'
						? 'Jobs you schedule will appear here.'
						: 'Try a different filter.'}
				>
					{#snippet icon()}<Clock />{/snippet}
				</EmptyState>
			{:else}
				<ul class="flex flex-col gap-0.5">
					{#each filtered as job (job.id)}
						<li>
							<button
								type="button"
								class="w-full rounded-lg px-3 py-2 text-left transition-colors {selectedId ===
								job.id
									? 'bg-secondary'
									: 'hover:bg-accent/60'}"
								data-testid="jobs-list-item"
								onclick={() => void select(job.id)}
							>
								<span class="block truncate text-sm font-medium">{job.name}</span>
								<span class="block truncate text-xs text-muted-foreground capitalize">
									{job.status} · {scheduleLabel(job)}
								</span>
							</button>
						</li>
					{/each}
				</ul>
			{/if}
		</div>

		<!-- Detail pane -->
		<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
			{#if !selected}
				{#if !loading}
					<EmptyState
						title="No job selected"
						description="Pick a job from the left to see its schedule and run history."
					>
						{#snippet icon()}<Clock />{/snippet}
					</EmptyState>
				{/if}
			{:else}
				<div class="mx-auto w-full max-w-2xl space-y-6 p-6" data-testid="jobs-detail">
					<div class="flex items-start gap-3">
						<div class="min-w-0 flex-1">
							<h2 class="flex items-center gap-2 text-lg font-semibold">
								<span class="truncate">{selected.name}</span>
								<span
									class="shrink-0 rounded-full bg-secondary px-2 py-0.5 text-[10px] font-medium uppercase text-muted-foreground"
								>
									{selected.status}
								</span>
							</h2>
							{#if selected.description}
								<p class="mt-0.5 text-sm text-muted-foreground">{selected.description}</p>
							{/if}
						</div>
						<a href="{base}/chat/{selected.conversationId}" class="shrink-0">
							<Button variant="outline" size="sm" data-testid="jobs-open-chat">
								<ExternalLink class="size-3.5" />
								Open chat
							</Button>
						</a>
					</div>

					<!-- Actions -->
					<div class="flex flex-wrap items-center gap-2" data-testid="jobs-actions">
						{#if selected.status === 'active'}
							<Button
								variant="outline"
								size="sm"
								disabled={busy}
								data-testid="jobs-pause"
								onclick={() => void act(pauseJob)}
							>
								<Pause class="size-3.5" /> Pause
							</Button>
							<Button
								variant="outline"
								size="sm"
								disabled={busy}
								data-testid="jobs-run-now"
								onclick={() => void runNow()}
							>
								<Zap class="size-3.5" /> Run now
							</Button>
						{:else if selected.status === 'paused'}
							<Button
								variant="outline"
								size="sm"
								disabled={busy}
								data-testid="jobs-resume"
								onclick={() => void act(resumeJob)}
							>
								<Play class="size-3.5" /> Resume
							</Button>
						{/if}
						{#if selected.status === 'active' || selected.status === 'paused'}
							<Button
								variant="ghost"
								size="sm"
								class="text-destructive hover:text-destructive"
								disabled={busy}
								data-testid="jobs-stop"
								onclick={() => void act(stopJob)}
							>
								<Square class="size-3.5" /> Stop
							</Button>
						{/if}
					</div>

					{#if error}
						<p class="text-xs text-destructive">{error}</p>
					{/if}

					<!-- Schedule -->
					<div class="rounded-xl border bg-card p-5">
						<h3 class="mb-3 text-sm font-semibold">Schedule</h3>
						<dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
							<dt class="text-muted-foreground">Type</dt>
							<dd class="capitalize">{selected.scheduleType.replace('_', ' ')}</dd>
							<dt class="text-muted-foreground">When</dt>
							<dd>{scheduleLabel(selected)}</dd>
							{#if selected.userTimezone}
								<dt class="text-muted-foreground">Timezone</dt>
								<dd>{selected.userTimezone}</dd>
							{/if}
							{#if selected.nextRunAt}
								<dt class="text-muted-foreground">Next run</dt>
								<dd>{relativeTime(selected.nextRunAt)}</dd>
							{/if}
							{#if selected.lastRunAt}
								<dt class="text-muted-foreground">Last run</dt>
								<dd>{relativeTime(selected.lastRunAt)}</dd>
							{/if}
							{#if selected.endsAt}
								<dt class="text-muted-foreground">Ends</dt>
								<dd>{relativeTime(selected.endsAt)}</dd>
							{/if}
						</dl>
					</div>

					<!-- Trigger prompt -->
					<div class="rounded-xl border bg-card p-5">
						<h3 class="mb-2 text-sm font-semibold">Trigger prompt</h3>
						<p class="text-sm whitespace-pre-wrap text-muted-foreground">
							{selected.triggerPrompt}
						</p>
					</div>

					<!-- Run history -->
					<div class="rounded-xl border bg-card p-5">
						<h3 class="mb-3 text-sm font-semibold">Recent runs</h3>
						{#if runsLoading}
							<div class="space-y-2">
								{#each [1, 2] as i (i)}
									<div class="h-8 animate-pulse rounded-md bg-muted/60"></div>
								{/each}
							</div>
						{:else if runs.length === 0}
							<p class="text-sm text-muted-foreground">No runs yet.</p>
						{:else}
							<ul class="flex flex-col gap-1" data-testid="jobs-runs">
								{#each runs as run (run.id)}
									<li class="flex items-center gap-2 text-sm">
										{#if run.status === 'success'}
											<CircleCheck class="size-4 shrink-0 text-success" />
										{:else if run.status === 'failed'}
											<CircleX class="size-4 shrink-0 text-destructive" />
										{:else}
											<Loader class="size-4 shrink-0 text-muted-foreground" />
										{/if}
										<span class="capitalize">{run.status}</span>
										<span class="text-muted-foreground">
											{#if run.startedAt}· {relativeTime(run.startedAt)}{/if}
											{#if runDuration(run)}· {runDuration(run)}{/if}
										</span>
										{#if run.errorMessage}
											<span class="min-w-0 flex-1 truncate text-xs text-destructive">
												{run.errorMessage}
											</span>
										{/if}
									</li>
								{/each}
							</ul>
						{/if}
					</div>
				</div>
			{/if}
		</div>
	</div>
</div>
