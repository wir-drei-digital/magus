<script lang="ts">
	import { Section as SettingsSection, ToggleSwitch } from '$lib/components/crud';
	import { session } from '$lib/stores/session.svelte';
	import { updateMemorySetting, updateProfileSetting } from '$lib/ash/api';

	let memoryEnabled = $state(session.user?.globalMemoryEnabled ?? true);
	let profileEnabled = $state(session.user?.profileEnabled ?? false);

	async function toggleMemory(next: boolean) {
		const prev = memoryEnabled;
		memoryEnabled = next;
		const userId = session.user?.id;
		if (!userId) return;
		const result = await updateMemorySetting(userId, next);
		if (!result.success) memoryEnabled = prev;
		else session.user = result.data;
	}

	async function toggleProfile(next: boolean) {
		const prev = profileEnabled;
		profileEnabled = next;
		const userId = session.user?.id;
		if (!userId) return;
		const result = await updateProfileSetting(userId, next);
		if (!result.success) profileEnabled = prev;
		else session.user = result.data;
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
</div>
