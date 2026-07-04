<script lang="ts">
	import { Section as SettingsSection, ToggleSwitch, confirmAction } from '$lib/components/crud';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import {
		updateMemorySetting,
		updateProfileSetting,
		listUserMemories,
		deactivateUserMemory,
		getUserProfile,
		clearUserProfile,
		type UserMemory,
		type UserProfileDoc
	} from '$lib/ash/api';
	import { bucketOptions } from '$lib/settings/memory-buckets';
	import { relativeTime } from '$lib/time';

	let memoryEnabled = $state(session.user?.globalMemoryEnabled ?? true);
	let profileEnabled = $state(session.user?.profileEnabled ?? false);

	async function toggleMemory(next: boolean) {
		const userId = session.user?.id;
		if (!userId) return;
		const prev = memoryEnabled;
		memoryEnabled = next;
		const result = await updateMemorySetting(userId, next);
		if (!result.success) memoryEnabled = prev;
		else session.user = result.data;
	}

	async function toggleProfile(next: boolean) {
		const userId = session.user?.id;
		if (!userId) return;
		const prev = profileEnabled;
		profileEnabled = next;
		const result = await updateProfileSetting(userId, next);
		if (!result.success) profileEnabled = prev;
		else session.user = result.data;
	}

	// Per-workspace memory browsing: "Personal" (null) plus one bucket per
	// workspace the user belongs to. Defaults to the user's active workspace.
	let selectedBucketId = $state<string | null>(session.user?.currentWorkspaceId ?? null);
	let memories = $state<UserMemory[]>([]);
	let memLoading = $state(true);
	const bucketOptionsList = $derived(
		bucketOptions(workbench.workspaces, session.user?.currentWorkspaceId ?? null)
	);

	async function loadMemories() {
		memLoading = true;
		const result = await listUserMemories(selectedBucketId);
		if (result.success) memories = result.data;
		memLoading = false;
	}

	$effect(() => {
		// Refetch whenever the selected bucket changes.
		selectedBucketId;
		void loadMemories();
	});

	async function removeMemory(m: UserMemory) {
		const ok = await confirmAction({
			title: 'Delete this memory?',
			description: `"${m.name}" will be removed from your memory.`,
			confirmLabel: 'Delete'
		});
		if (!ok) return;
		const result = await deactivateUserMemory(m.id);
		if (result.success) memories = memories.filter((x) => x.id !== m.id);
	}

	let profile = $state<UserProfileDoc | null>(null);
	let profileLoading = $state(true);

	async function loadProfile() {
		profileLoading = true;
		const userId = session.user?.id;
		if (!userId) {
			profileLoading = false;
			return;
		}
		const result = await getUserProfile(userId, selectedBucketId);
		if (result.success) profile = result.data;
		profileLoading = false;
	}

	$effect(() => {
		// Refetch whenever the selected bucket changes.
		selectedBucketId;
		void loadProfile();
	});

	async function resetProfile() {
		if (!profile) return;
		const ok = await confirmAction({
			title: 'Reset your profile?',
			description:
				'The distilled profile for this workspace will be cleared. It rebuilds from your memories over time.',
			confirmLabel: 'Reset'
		});
		if (!ok) return;
		const result = await clearUserProfile(profile.id);
		if (result.success) profile = { ...profile, document: '', tokenEstimate: 0 };
	}
</script>

<div class="space-y-6" data-testid="settings-memory">
	<SettingsSection
		title="Memory"
		description="Let Magus remember facts about you across conversations."
	>
		<ToggleSwitch
			checked={memoryEnabled}
			label="Enable memory"
			testid="memory-toggle"
			onchange={(next) => void toggleMemory(next)}
		/>
	</SettingsSection>

	<SettingsSection
		title="Profile"
		description="A short living summary distilled from your memories."
	>
		<ToggleSwitch
			checked={profileEnabled}
			disabled={!memoryEnabled}
			label="Enable profile"
			testid="profile-toggle"
			onchange={(next) => void toggleProfile(next)}
		/>
		{#if !memoryEnabled}
			<p class="mt-1 text-xs text-muted-foreground" data-testid="profile-disabled-note">
				Turn memory on to use the profile.
			</p>
		{/if}
	</SettingsSection>

	<SettingsSection title="Your memories" description="Facts Magus has stored about you.">
		{#snippet actions()}
			<select
				data-testid="memory-bucket-filter"
				bind:value={selectedBucketId}
				class="rounded-md border border-input bg-secondary px-2 py-1 text-xs outline-none focus:border-primary/60"
			>
				{#each bucketOptionsList as option (option.value ?? 'personal')}
					<option value={option.value}>{option.label}</option>
				{/each}
			</select>
		{/snippet}

		{#if memLoading}
			<div class="h-10 animate-pulse rounded-lg bg-muted/60"></div>
		{:else if memories.length === 0}
			<p class="text-xs text-muted-foreground" data-testid="user-memories-empty">No memories yet.</p>
		{:else}
			<div class="flex flex-col gap-1.5" data-testid="user-memories">
				{#each memories as m (m.id)}
					<div class="flex items-start justify-between gap-2 rounded-lg bg-secondary/60 px-3 py-2">
						<span class="min-w-0">
							<span class="text-sm font-medium">{m.name}</span>
							{#if m.kind}
								<span class="ml-1.5 text-xs text-muted-foreground">{m.kind}</span>
							{/if}
							{#if m.summary}
								<span class="mt-0.5 block truncate text-xs text-muted-foreground">{m.summary}</span>
							{/if}
							{#if m.updatedAt}
								<span class="mt-0.5 block text-xs text-muted-foreground"
									>Updated {relativeTime(m.updatedAt)}</span
								>
							{/if}
						</span>
						<button
							type="button"
							class="shrink-0 rounded px-2 py-1 text-xs text-destructive hover:bg-destructive/10"
							data-testid={`memory-delete-${m.id}`}
							onclick={() => void removeMemory(m)}
						>
							Delete
						</button>
					</div>
				{/each}
			</div>
		{/if}
	</SettingsSection>

	<SettingsSection
		title="Profile summary"
		description="The distilled summary for the selected workspace."
	>
		{#if profileLoading}
			<div class="h-16 animate-pulse rounded-lg bg-muted/60"></div>
		{:else if !profile || profile.document === ''}
			<p class="text-xs text-muted-foreground" data-testid="profile-empty">
				No profile yet. It is distilled from your memories over time.
			</p>
		{:else}
			<div class="space-y-2" data-testid="profile-card">
				<pre class="whitespace-pre-wrap rounded-lg bg-secondary/60 p-3 text-xs">{profile.document}</pre>
				{#if profile.lastDistilledAt}
					<p class="text-xs text-muted-foreground">
						Last updated {relativeTime(profile.lastDistilledAt)}
					</p>
				{/if}
				<button
					type="button"
					class="rounded px-2 py-1 text-xs text-destructive hover:bg-destructive/10"
					data-testid="profile-reset"
					onclick={() => void resetProfile()}
				>
					Reset profile
				</button>
			</div>
		{/if}
	</SettingsSection>
</div>
