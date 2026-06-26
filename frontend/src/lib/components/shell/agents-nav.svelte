<script lang="ts">
	import { page } from '$app/state';
	import { base } from '$app/paths';
	import { Bot } from '@lucide/svelte';
	import type { AgentSummary } from '$lib/ash/api';
	import { compactTime } from '$lib/time';
	import { agentsNav } from '$lib/stores/agents-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';

	let { query = '' }: { query?: string } = $props();

	$effect(() => {
		void agentsNav.load(session.user?.currentWorkspaceId ?? null);
	});

	const matches = (agent: AgentSummary) =>
		query === '' ||
		agent.name.toLowerCase().includes(query.toLowerCase()) ||
		agent.handle.toLowerCase().includes(query.toLowerCase());

	const shared = $derived(agentsNav.shared.filter(matches));
	const personal = $derived(agentsNav.personal.filter(matches));
</script>

{#snippet agentRow(agent: AgentSummary)}
	<Sidebar.MenuItem>
		<Sidebar.MenuButton
			isActive={page.url.pathname.endsWith(`/agents/${agent.id}`)}
			class="h-auto py-2"
		>
			{#snippet child({ props })}
				<a {...props} href="{base}/agents/{agent.id}">
					{#if agent.imageUrl}
						<img
							src={agent.imageUrl}
							alt={agent.name}
							class="size-7 shrink-0 rounded-full border border-input object-cover"
						/>
					{:else}
						<span
							class="flex size-7 shrink-0 items-center justify-center rounded-full border border-input bg-secondary text-sm"
						>
							{#if agent.icon}{agent.icon}{:else}<Bot class="size-4 text-muted-foreground" />{/if}
						</span>
					{/if}
					<span class="min-w-0 flex-1">
						<span class="flex items-center gap-1.5">
							<span
								class="size-1.5 shrink-0 rounded-full {agent.isPaused
									? 'bg-muted-foreground/50'
									: 'bg-success'}"
								title={agent.isPaused ? 'Paused' : 'Active'}
							></span>
							<span class="min-w-0 truncate text-sm font-medium">{agent.name}</span>
							<span class="ml-auto shrink-0 text-[10px] text-muted-foreground">
								{compactTime(agent.updatedAt)}
							</span>
						</span>
						{#if agent.description}
							<span class="block truncate text-xs text-muted-foreground">{agent.description}</span>
						{/if}
					</span>
				</a>
			{/snippet}
		</Sidebar.MenuButton>
	</Sidebar.MenuItem>
{/snippet}

{#snippet section(title: string, agents: AgentSummary[])}
	{#if agents.length > 0}
		<Sidebar.Group>
			<Sidebar.GroupLabel>{title}</Sidebar.GroupLabel>
			<Sidebar.GroupContent>
				<Sidebar.Menu>
					{#each agents as agent (agent.id)}
						{@render agentRow(agent)}
					{/each}
				</Sidebar.Menu>
			</Sidebar.GroupContent>
		</Sidebar.Group>
	{/if}
{/snippet}

<div data-testid="agents-nav" class="contents">
	{#if agentsNav.loading}
		<Sidebar.Group>
			<Sidebar.GroupContent>
				<Sidebar.Menu>
					{#each [1, 2, 3] as i (i)}
						<Sidebar.MenuItem>
							<Sidebar.MenuSkeleton />
						</Sidebar.MenuItem>
					{/each}
				</Sidebar.Menu>
			</Sidebar.GroupContent>
		</Sidebar.Group>
	{:else if shared.length === 0 && personal.length === 0}
		<div class="p-4 pt-3 text-sm text-muted-foreground">
			{#if query}
				No matches.
			{:else}
				<p class="font-medium text-foreground">No agents yet</p>
				<p class="mt-0.5 text-xs">Create your first with “New agent” above.</p>
			{/if}
		</div>
	{:else}
		{#if workbench.navFilter !== 'personal'}
			{@render section('Shared', shared)}
		{/if}
		{#if workbench.navFilter !== 'shared'}
			{@render section(session.user?.currentWorkspaceId ? 'Personal' : 'Agents', personal)}
		{/if}
	{/if}
</div>
