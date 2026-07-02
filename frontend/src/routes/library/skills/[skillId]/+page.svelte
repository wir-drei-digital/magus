<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { ArrowLeft, Box, FileCode, Package, Star, Wrench } from '@lucide/svelte';
	import {
		destroySkill,
		favoriteSkill,
		getSkill,
		mySkillFavorites,
		shareSkillToTeam,
		skillDownloadUrl,
		unfavoriteSkill,
		unshareSkillFromTeam,
		type SkillDetail
	} from '$lib/ash/api';
	import Markdown from '$lib/components/chat/markdown.svelte';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { confirmAction } from '$lib/components/crud';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import SkillFormDialog from '$lib/components/shell/skill-form-dialog.svelte';

	const skillId = $derived(page.params.skillId!);
	const isNew = $derived(skillId === 'new');

	let skill = $state<SkillDetail | null>(null);
	let loadError = $state<string | null>(null);
	// Share / delete failures surface in this banner.
	let saveError = $state<string | null>(null);

	// ?edit=true deep links open straight into the edit dialog (classic parity),
	// then strip the param so it doesn't leak back into the gallery hrefs.
	let editOpen = $state(false);
	let editParamApplied = false;
	$effect(() => {
		if (editParamApplied || !skill) return;
		editParamApplied = true;
		if (page.url.searchParams.get('edit') === 'true') {
			editOpen = true;
			const url = new URL(page.url);
			url.searchParams.delete('edit');
			void goto(`${url.pathname}${url.search}`, { replaceState: true });
		}
	});

	$effect(() => {
		const id = skillId;
		skill = null;
		loadError = null;
		saveError = null;

		// Creation lives in the shared "New skill" dialog; redirect and open it.
		if (id === 'new') {
			void goto(`${base}/library?new=skill`, { replaceState: true });
			return;
		}

		void getSkill(id).then((result) => {
			if (id !== skillId) return;
			if (result.success) {
				skill = result.data;
			} else {
				loadError = result.errors[0]?.message ?? 'Skill could not be loaded';
			}
		});
	});

	async function remove() {
		if (!skill) return;
		const skillName = skill?.name ?? '';
		const ok = await confirmAction({
			title: `Delete ${skillName}?`,
			description: 'This skill will be permanently removed.',
			confirmLabel: 'Delete'
		});
		if (!ok) return;
		const result = await destroySkill(skillId);
		if (result.success) {
			libraryNav.refresh();
			await goto(`${base}/library`);
		} else {
			saveError = result.errors[0]?.message ?? 'Skill could not be deleted';
		}
	}

	async function toggleFavorite() {
		if (!skill) return;
		const id = skillId;
		if (skill.isFavorited) {
			// The favorite row id comes from the favorites listing.
			const favorites = await mySkillFavorites();
			if (!favorites.success) return;
			const favorite = favorites.data.find((entry) => entry.skillId === skill!.id);
			if (favorite) await unfavoriteSkill(favorite.id);
		} else {
			await favoriteSkill(skill.id);
		}
		const refreshed = await getSkill(id);
		// Drop stale responses after navigating to another skill mid-flight.
		if (id === skillId && refreshed.success) skill = refreshed.data;
		libraryNav.refresh();
	}

	async function toggleShare() {
		if (!skill) return;
		const result = skill.isSharedToWorkspace
			? await unshareSkillFromTeam(skill.id)
			: await shareSkillToTeam(skill.id);
		if (result.success) {
			skill = result.data;
			libraryNav.refresh();
		} else {
			saveError = result.errors[0]?.message ?? 'Sharing failed';
		}
	}

	/** Format a file size in bytes into a human-readable string. */
	function formatSize(bytes: unknown): string {
		const n = typeof bytes === 'number' ? bytes : Number(bytes);
		if (!Number.isFinite(n) || n < 0) return '';
		if (n < 1024) return `${n} B`;
		if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
		return `${(n / (1024 * 1024)).toFixed(1)} MB`;
	}

	type ManifestEntry = {
		path: string;
		size: unknown;
		sha256?: unknown;
		executable?: unknown;
	};

	function toEntry(raw: Record<string, unknown>): ManifestEntry {
		return {
			path: String(raw.path ?? ''),
			size: raw.size,
			sha256: raw.sha256,
			executable: raw.executable
		};
	}

	function isExecutable(entry: ManifestEntry): boolean {
		return entry.executable === true || String(entry.path).startsWith('scripts/');
	}
</script>

<svelte:head>
	<title>Magus — {isNew ? 'New skill' : (skill?.displayName ?? skill?.name ?? 'Skill')}</title>
</svelte:head>

<div class="flex h-full min-h-0 flex-col" data-testid="skill-detail">
	{#if loadError}
		<p class="p-6 text-sm text-destructive">{loadError}</p>
	{:else if !skill}
		<div class="space-y-3 p-6">
			<div class="h-5 w-1/3 animate-pulse rounded bg-muted"></div>
			<div class="h-40 animate-pulse rounded-xl bg-muted"></div>
		</div>
	{:else if skill}
		<!-- Read view -->
		{#if saveError}
			<p class="border-b bg-destructive/10 px-6 py-1.5 text-xs text-destructive">{saveError}</p>
		{/if}
		<header class="flex shrink-0 items-center gap-2.5 border-b py-3 pr-6 pl-14 md:pl-4">
			<button
				type="button"
				class="wb-pill-btn wb-pill-btn-square shrink-0"
				aria-label="Back to library"
				data-testid="reader-back"
				onclick={() => void goto(`${base}/library${page.url.search}`)}
			>
				<ArrowLeft class="size-4" />
			</button>
			<span
				class="flex size-8 shrink-0 items-center justify-center rounded-full border border-input bg-secondary"
				title={skill.hasExecutableBundle ? 'Runnable skill' : 'Prompt-only skill'}
			>
				{#if skill.hasExecutableBundle}
					<Box class="size-4 text-muted-foreground" />
				{:else}
					<FileCode class="size-4 text-muted-foreground" />
				{/if}
			</span>
			<div class="min-w-0 flex-1">
				<h1 class="truncate text-base font-semibold" data-testid="skill-title">
					{skill.displayName ?? skill.name}
				</h1>
				{#if skill.description}
					<p class="truncate text-xs text-muted-foreground">{skill.description}</p>
				{/if}
			</div>
			<div class="flex shrink-0 items-center gap-1.5">
				<button
					type="button"
					class="wb-pill-btn wb-pill-btn-square shrink-0 {skill.isFavorited
						? '!text-favorite'
						: ''}"
					aria-label={skill.isFavorited ? 'Unfavorite' : 'Favorite'}
					data-testid="skill-favorite"
					onclick={() => void toggleFavorite()}
				>
					<Star class="size-3.5 {skill.isFavorited ? 'fill-favorite' : ''}" />
				</button>
				<button
					type="button"
					class="wb-pill-btn shrink-0"
					data-testid="skill-edit"
					onclick={() => (editOpen = true)}
				>
					Edit
				</button>
				<DropdownMenu.Root>
					<DropdownMenu.Trigger
						class="wb-pill-btn wb-pill-btn-square shrink-0"
						aria-label="Skill actions"
					>
						⋯
					</DropdownMenu.Trigger>
					<DropdownMenu.Content align="end">
						{#if session.user?.currentWorkspaceId}
							<DropdownMenu.Item data-testid="skill-share" onSelect={() => void toggleShare()}>
								{skill.isSharedToWorkspace ? 'Unshare from workspace' : 'Share to workspace'}
							</DropdownMenu.Item>
							<DropdownMenu.Separator />
						{/if}
						<DropdownMenu.Item
							variant="destructive"
							data-testid="skill-delete"
							onSelect={() => void remove()}
						>
							Delete
						</DropdownMenu.Item>
					</DropdownMenu.Content>
				</DropdownMenu.Root>
			</div>
		</header>

		<div class="wb-scroll mx-auto w-full max-w-2xl min-h-0 flex-1 overflow-y-auto p-6">
			<!-- Meta chips: version, license, format, runnable -->
			<div class="mb-4 flex flex-wrap items-center gap-1.5">
				{#if skill.hasExecutableBundle}
					<span
						class="rounded-full border border-emerald-200 bg-emerald-50 px-2 py-0.5 text-[10px] font-medium text-emerald-700 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-400"
					>
						Runnable in sandbox
					</span>
				{:else}
					<span
						class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground"
					>
						Prompt-only skill
					</span>
				{/if}
				{#if skill.version}
					<span
						class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground"
					>
						v{skill.version}
					</span>
				{/if}
				{#if skill.license}
					<span
						class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground"
					>
						{skill.license}
					</span>
				{/if}
				{#if skill.sourceUrl}
					<a
						href={skill.sourceUrl}
						target="_blank"
						rel="noopener noreferrer"
						class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground transition-colors hover:bg-muted"
					>
						Source
					</a>
				{/if}
				{#if skill.isSharedToWorkspace}
					<span
						class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground"
					>
						Workspace
					</span>
				{/if}
			</div>

			<!-- Requested tools chips -->
			{#if skill.requestedTools && skill.requestedTools.length > 0}
				<div class="mb-4">
					<h2 class="mb-1.5 text-xs font-medium text-muted-foreground">Required tools</h2>
					<div class="flex flex-wrap gap-1.5">
						{#each skill.requestedTools as tool (tool)}
							<span
								class="inline-flex items-center gap-1 rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground"
							>
								<Wrench class="size-2.5" />
								{tool}
							</span>
						{/each}
					</div>
				</div>
			{/if}

			<!-- Instructions body rendered as Markdown -->
			{#if skill.body}
				<div class="rounded-xl border border-input bg-card/60 p-4">
					<Markdown text={skill.body} />
				</div>
			{/if}

			<!-- Artifacts section: only for skills with an executable bundle -->
			{#if skill.hasExecutableBundle && skill.fileManifest && skill.fileManifest.length > 0}
				<section class="mt-6" data-testid="skill-artifacts">
					<div class="mb-2 flex items-center justify-between gap-2">
						<h2 class="flex items-center gap-1.5 text-sm font-medium">
							<Package class="size-3.5 text-muted-foreground" />
							Artifacts
						</h2>
						<a
							href={skillDownloadUrl(skill)}
							download
							class="wb-pill-btn text-xs"
							data-testid="skill-download"
						>
							Download bundle
						</a>
					</div>
					<div class="overflow-hidden rounded-xl border border-input">
						<table class="w-full text-xs">
							<thead>
								<tr class="border-b bg-muted/40">
									<th class="py-1.5 pl-3 pr-2 text-left font-medium text-muted-foreground">Path</th>
									<th class="py-1.5 pr-3 text-right font-medium text-muted-foreground">Size</th>
								</tr>
							</thead>
							<tbody>
								{#each skill.fileManifest as rawEntry (String(rawEntry.path ?? ''))}
									{@const entry = toEntry(rawEntry)}
									<tr class="border-b last:border-0 hover:bg-muted/20">
										<td class="py-1.5 pl-3 pr-2 font-mono">
											{entry.path}
											{#if isExecutable(entry)}
												<span
													class="ml-1 rounded bg-amber-100 px-1 py-px text-[9px] font-semibold text-amber-700 dark:bg-amber-950 dark:text-amber-400"
													>exec</span
												>
											{/if}
										</td>
										<td class="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">
											{formatSize(entry.size)}
										</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				</section>
			{:else if skill.hasExecutableBundle}
				<!-- Bundle flagged but manifest not yet available -->
				<section class="mt-6" data-testid="skill-artifacts">
					<div class="mb-2 flex items-center justify-between gap-2">
						<h2 class="flex items-center gap-1.5 text-sm font-medium">
							<Package class="size-3.5 text-muted-foreground" />
							Artifacts
						</h2>
						<a
							href={skillDownloadUrl(skill)}
							download
							class="wb-pill-btn text-xs"
							data-testid="skill-download"
						>
							Download bundle
						</a>
					</div>
					<p class="text-xs text-muted-foreground">No file manifest available.</p>
				</section>
			{/if}

			<!-- Compatibility note -->
			{#if skill.compatibility}
				<p class="mt-4 text-xs text-muted-foreground">Compatibility: {skill.compatibility}</p>
			{/if}
		</div>
	{/if}
</div>

<SkillFormDialog bind:open={editOpen} {skill} onSaved={(updated) => (skill = updated)} />
