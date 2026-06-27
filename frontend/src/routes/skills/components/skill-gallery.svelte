<script lang="ts">
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { Download, Plus, Search, BookMarked } from '@lucide/svelte';
	import type { SkillSummary } from '$lib/ash/api';
	import { skillsNav } from '$lib/stores/skills-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { Button } from '$lib/components/ui/button';
	import { EmptyState } from '$lib/components/ui/empty-state';
	import SkillCard from './skill-card.svelte';

	let { selectedId = null, compact = false }: { selectedId?: string | null; compact?: boolean } =
		$props();

	const SCOPES = [
		['all', 'All'],
		['personal', 'Personal'],
		['workspace', 'Workspace']
	] as const;

	let query = $state('');
	let scopeFilter = $state<'all' | 'personal' | 'workspace'>('all');
	let sort = $state<'name' | 'recent'>('name');

	$effect(() => {
		void skillsNav.load(session.user?.currentWorkspaceId ?? null);
	});

	// The rail sets these; the gallery reads them so the two stay in sync via the
	// URL (and they survive deep links + the back button).
	const urlScope = $derived(page.url.searchParams.get('scope'));

	// All skills = workspace ∪ personal.
	const allSkills = $derived<SkillSummary[]>([...skillsNav.workspace, ...skillsNav.personal]);

	// The URL scope/filter picks the base set; the toolbar narrows within it.
	const scoped = $derived.by(() => {
		if (urlScope === 'workspace') return skillsNav.workspace;
		if (urlScope === 'personal') return skillsNav.personal;
		if (scopeFilter === 'workspace') return skillsNav.workspace;
		if (scopeFilter === 'personal') return skillsNav.personal;
		return allSkills;
	});

	const shown = $derived.by(() => {
		const q = query.trim().toLowerCase();
		const filtered = scoped.filter((s) => {
			if (!q) return true;
			const label = (s.displayName ?? s.name).toLowerCase();
			return (
				label.includes(q) ||
				(s.description?.toLowerCase().includes(q) ?? false)
			);
		});
		return [...filtered].sort((a, b) => {
			const nameA = (a.displayName ?? a.name).toLowerCase();
			const nameB = (b.displayName ?? b.name).toLowerCase();
			return sort === 'name' ? nameA.localeCompare(nameB) : 0;
		});
	});

	const heading = $derived(
		urlScope === 'workspace'
			? 'Workspace'
			: urlScope === 'personal'
				? 'Personal'
				: scopeFilter === 'workspace'
					? 'Workspace'
					: scopeFilter === 'personal'
						? 'Personal'
						: 'All skills'
	);

	const filtering = $derived(query.trim() !== '' || scopeFilter !== 'all');
	const rawTotal = $derived(allSkills.length);
	const cols = $derived(compact ? '160px' : '220px');

	// Keep the active scope in the URL when opening a detail so the rail stays
	// highlighted and the narrowed gallery keeps showing the same subset.
	const cardHref = (id: string) => `${base}/skills/${id}${page.url.search}`;
</script>

<div class="flex h-full min-h-0 flex-col" data-testid="skill-gallery">
	<header class="flex shrink-0 items-center gap-2 border-b py-3 pr-4 pl-14 md:pl-4">
		<BookMarked class="size-4 shrink-0 text-muted-foreground" />
		<h1 class="flex-1 truncate text-base font-semibold">Skills</h1>
		<Button size="sm" href="{base}/skills/new" data-testid="gallery-new-skill">
			<Plus class="size-3.5" /> New skill
		</Button>
	</header>

	<div class="flex shrink-0 flex-wrap items-center gap-2 border-b px-4 py-2">
		<label class="relative flex min-w-[9rem] flex-1 items-center">
			<Search class="pointer-events-none absolute left-2.5 size-3.5 text-muted-foreground" />
			<input
				bind:value={query}
				placeholder="Search skills"
				data-testid="gallery-search"
				class="w-full rounded-md border border-input bg-secondary py-1.5 pr-2.5 pl-8 text-sm outline-none focus:border-primary/60"
			/>
		</label>

		<div class="flex shrink-0 items-center gap-0.5 rounded-md border border-input p-0.5 text-xs">
			{#each SCOPES as [value, label] (value)}
				<button
					type="button"
					class="rounded px-2 py-1 transition-colors {scopeFilter === value
						? 'bg-secondary font-medium text-foreground'
						: 'text-muted-foreground hover:text-foreground'}"
					onclick={() => (scopeFilter = value)}
				>
					{label}
				</button>
			{/each}
		</div>

		<select
			bind:value={sort}
			aria-label="Sort skills"
			class="shrink-0 rounded-md border border-input bg-secondary px-2 py-1.5 text-xs text-muted-foreground outline-none focus:border-primary/60"
		>
			<option value="name">A-Z</option>
			<option value="recent">Recent</option>
		</select>
	</div>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
		<div class="p-4 {compact ? '' : 'mx-auto max-w-5xl md:p-6'}">
			{#if skillsNav.loading && rawTotal === 0}
				<div
					class="grid gap-3"
					style="grid-template-columns: repeat(auto-fill, minmax({cols}, 1fr));"
				>
					{#each [1, 2, 3, 4, 5, 6] as i (i)}
						<div class="h-28 animate-pulse rounded-xl border border-border bg-card/50"></div>
					{/each}
				</div>
			{:else if rawTotal === 0}
				<EmptyState
					class="h-auto py-16"
					data-testid="gallery-empty"
					title="No skills yet"
					description="Skills extend what the AI can do: install one from a URL or create your own."
				>
					{#snippet icon()}<BookMarked />{/snippet}
					<div class="flex items-center gap-2">
						<Button size="sm" href="{base}/skills/new">
							<Plus class="size-3.5" /> New skill
						</Button>
						<Button
							size="sm"
							variant="outline"
							data-testid="import-skill-empty"
							onclick={() => (skillsNav.importOpen = true)}
						>
							<Download class="size-3.5" /> Import skill
						</Button>
					</div>
				</EmptyState>
			{:else}
				<div class="mb-3 flex items-baseline gap-2">
					<h2 class="text-xs font-medium text-muted-foreground">{heading}</h2>
					<span class="text-[11px] text-muted-foreground/70">{shown.length}</span>
				</div>

				{#if shown.length === 0}
					<p
						class="py-12 text-center text-sm text-muted-foreground"
						data-testid="gallery-scope-empty"
					>
						{#if filtering}
							No skills match your search.
						{:else if urlScope === 'workspace' || scopeFilter === 'workspace'}
							Nothing shared to this workspace yet.
						{:else if urlScope === 'personal' || scopeFilter === 'personal'}
							No personal skills yet.
						{:else}
							No skills here yet.
						{/if}
					</p>
				{:else}
					<div
						class="grid gap-3"
						style="grid-template-columns: repeat(auto-fill, minmax({cols}, 1fr));"
					>
						{#each shown as skill (skill.id)}
							<SkillCard
								{skill}
								href={cardHref(skill.id)}
								selected={skill.id === selectedId}
								{compact}
							/>
						{/each}
					</div>
				{/if}
			{/if}
		</div>
	</div>
</div>
