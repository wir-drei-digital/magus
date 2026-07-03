<script lang="ts">
	import type { Snippet } from 'svelte';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { BarChart3, Building2, Settings, Users } from '@lucide/svelte';
	import { getWorkspaceBySlug, listWorkspaceMembers } from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import { setWorkspaceAdmin, type WorkspaceAdminState } from '$lib/components/workspaces/context';

	let { children }: { children: Snippet } = $props();

	const slug = $derived(page.params.slug!);

	const state = $state<WorkspaceAdminState>({
		slug: '',
		workspace: null,
		members: [],
		loading: true,
		error: null,
		isAdmin: false,
		currentMemberId: null,
		reloadWorkspace,
		reloadMembers
	});
	setWorkspaceAdmin(state);

	async function reloadWorkspace() {
		const result = await getWorkspaceBySlug(slug);
		if (result.success) {
			state.workspace = result.data;
			state.error = null;
		} else {
			state.workspace = null;
			state.error = result.errors[0]?.message ?? 'Workspace not found.';
		}
	}

	async function reloadMembers() {
		if (!state.workspace) {
			state.members = [];
			return;
		}
		const result = await listWorkspaceMembers(state.workspace.id);
		if (result.success) {
			state.members = result.data;
			recomputeAdmin();
		}
	}

	function recomputeAdmin() {
		const uid = session.user?.id ?? null;
		const own = state.members.find((member) => member.user?.id === uid && member.isActive);
		state.currentMemberId = own?.id ?? null;
		state.isAdmin = own?.role === 'admin';
	}

	// (Re)load whenever the slug changes, once the signed-in user is known (the
	// admin gate needs their id). The async body isn't tracked past the first
	// await, so only slug/uid are dependencies.
	$effect(() => {
		const uid = session.user?.id;
		state.slug = slug;
		if (!uid) return;
		state.loading = true;
		void (async () => {
			await reloadWorkspace();
			await reloadMembers();
			state.loading = false;
		})();
	});

	const tabs = $derived([
		{ id: 'settings', label: 'Settings', icon: Settings, href: `${base}/workspaces/${slug}` },
		{ id: 'members', label: 'Members', icon: Users, href: `${base}/workspaces/${slug}/members` },
		{ id: 'usage', label: 'Usage', icon: BarChart3, href: `${base}/workspaces/${slug}/usage` }
	]);

	const activeTab = $derived.by(() => {
		const path = page.url.pathname;
		if (path.endsWith('/members')) return 'members';
		if (path.endsWith('/usage')) return 'usage';
		return 'settings';
	});
</script>

<svelte:head>
	<title>Magus — {state.workspace?.name ?? 'Workspace'}</title>
</svelte:head>

<div class="flex h-full min-h-0 flex-col" data-testid="workspace-admin-view">
	<header
		class="flex shrink-0 items-center gap-2 border-b bg-background/80 py-3 pr-6 pl-14 md:pl-6"
	>
		<Building2 class="size-4 shrink-0 text-muted-foreground" />
		<h1 class="min-w-0 flex-1 truncate text-base font-semibold">
			{state.workspace?.name ?? 'Workspace'}
		</h1>
	</header>

	{#if state.loading}
		<div class="flex flex-1 items-center justify-center">
			<span
				class="size-5 animate-spin rounded-full border-2 border-current border-t-transparent text-muted-foreground"
			></span>
		</div>
	{:else if state.error || !state.workspace}
		<div
			class="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center"
			data-testid="workspace-error"
		>
			<p class="text-sm font-medium">This workspace isn't available.</p>
			<p class="max-w-sm text-xs text-muted-foreground">
				{state.error ?? "It may have been deleted, or you don't have access to it."}
			</p>
			<a href="{base}/chat" class="text-sm text-primary hover:underline">Back to chat</a>
		</div>
	{:else if !state.isAdmin}
		<div class="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
			<p class="text-sm font-medium">Only workspace admins can manage this workspace.</p>
			<a href="{base}/chat" class="text-sm text-primary hover:underline">Back to chat</a>
		</div>
	{:else}
		<div class="flex min-h-0 flex-1 flex-col">
			<!-- Horizontal pill tabs on top, matching the custom-agent settings nav. -->
			<nav
				class="wb-scroll flex shrink-0 items-center gap-1.5 overflow-x-auto border-b px-4 py-2"
				data-testid="workspace-nav"
			>
				{#each tabs as tab (tab.id)}
					<a
						href={tab.href}
						data-testid="workspace-nav-{tab.id}"
						aria-current={activeTab === tab.id ? 'page' : undefined}
						class="flex shrink-0 items-center gap-2 rounded-full px-3 py-1 text-sm whitespace-nowrap transition-colors {activeTab ===
						tab.id
							? 'bg-secondary font-medium text-foreground'
							: 'text-muted-foreground hover:bg-accent/40 hover:text-foreground'}"
					>
						<tab.icon class="size-4 shrink-0" />
						<span>{tab.label}</span>
					</a>
				{/each}
			</nav>

			<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
				<div class="mx-auto w-full max-w-2xl p-6">
					{@render children()}
				</div>
			</div>
		</div>
	{/if}
</div>
