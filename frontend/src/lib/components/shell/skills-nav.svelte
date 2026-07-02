<script lang="ts">
	import { page } from '$app/state';
	import { base } from '$app/paths';
	import { LayoutGrid, User, Users } from '@lucide/svelte';
	import type { SkillSummary } from '$lib/ash/api';
	import { skillsNav } from '$lib/stores/skills-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';

	// The gallery (/skills/+layout.svelte) is the browse surface; this rail is
	// a set of scope filters that drive it via ?scope= in the URL.
	$effect(() => {
		void skillsNav.load(session.user?.currentWorkspaceId ?? null);
	});

	// All skills = personal ∪ workspace.
	const allSkills = $derived<SkillSummary[]>([...skillsNav.personal, ...skillsNav.workspace]);

	const scopes = $derived([
		{
			key: null as string | null,
			label: 'All skills',
			icon: LayoutGrid,
			count: allSkills.length
		},
		{ key: 'personal', label: 'Personal', icon: User, count: skillsNav.personal.length },
		// Workspace scope only makes sense inside a workspace context.
		...(session.user?.currentWorkspaceId
			? [
					{
						key: 'workspace',
						label: 'Workspace',
						icon: Users,
						count: skillsNav.workspace.length
					}
				]
			: [])
	]);

	const activeScope = $derived(page.url.searchParams.get('scope'));
	const inSkills = $derived(page.url.pathname.startsWith(`${base}/skills`));

	const scopeHref = (key: string | null) =>
		key ? `${base}/skills?scope=${key}` : `${base}/skills`;
</script>

<div data-testid="skills-nav" class="contents">
	{#if skillsNav.loading && allSkills.length === 0}
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
	{:else}
		<Sidebar.Group>
			<Sidebar.GroupLabel>Library</Sidebar.GroupLabel>
			<Sidebar.GroupContent>
				<Sidebar.Menu>
					{#each scopes as scope (scope.label)}
						{@const active = inSkills && (activeScope ?? null) === scope.key}
						<Sidebar.MenuItem>
							<Sidebar.MenuButton
								isActive={active}
								data-testid="skills-scope-{scope.key ?? 'all'}"
							>
								{#snippet child({ props })}
									<a {...props} href={scopeHref(scope.key)}>
										<scope.icon class="text-muted-foreground" />
										<span>{scope.label}</span>
									</a>
								{/snippet}
							</Sidebar.MenuButton>
							<Sidebar.MenuBadge class="text-[10px] text-muted-foreground">
								{scope.count}
							</Sidebar.MenuBadge>
						</Sidebar.MenuItem>
					{/each}
				</Sidebar.Menu>
			</Sidebar.GroupContent>
		</Sidebar.Group>
	{/if}
</div>
