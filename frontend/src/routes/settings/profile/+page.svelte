<script lang="ts">
	import { onMount } from 'svelte';
	import { Button } from '$lib/components/ui/button';
	import ProfileImagePicker from '$lib/components/settings/profile-image-picker.svelte';
	import { Section as SettingsSection, CONTROL_CLASS } from '$lib/components/crud';
	import {
		changeUserPassword,
		requestEmailChange,
		setUserPassword,
		updateUserSettings,
		userSettings,
		type UserSettings
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';

	const FIELD = CONTROL_CLASS;

	let settings = $state<UserSettings | null>(null);
	let loading = $state(true);

	// Profile form.
	let displayName = $state('');
	let name = $state('');
	let language = $state<'de' | 'en'>('en');
	let savingProfile = $state(false);
	let profileMessage = $state<{ kind: 'ok' | 'error'; text: string } | null>(null);

	// Email change.
	let newEmail = $state('');
	let savingEmail = $state(false);
	let emailMessage = $state<{ kind: 'ok' | 'error'; text: string } | null>(null);

	// Password.
	let currentPassword = $state('');
	let newPassword = $state('');
	let confirmPassword = $state('');
	let savingPassword = $state(false);
	let passwordMessage = $state<{ kind: 'ok' | 'error'; text: string } | null>(null);

	const profileDirty = $derived(
		settings !== null &&
			(displayName !== (settings.displayName ?? '') ||
				name !== (settings.name ?? '') ||
				language !== settings.language)
	);

	onMount(() => {
		void load();
	});

	async function load() {
		const result = await userSettings();
		if (result.success) {
			settings = result.data;
			displayName = result.data.displayName ?? '';
			name = result.data.name ?? '';
			language = result.data.language;
		}
		loading = false;
	}

	function adopt(next: UserSettings) {
		settings = next;
		displayName = next.displayName ?? '';
		name = next.name ?? '';
		language = next.language;
	}

	async function saveProfile() {
		if (!settings || savingProfile) return;
		savingProfile = true;
		profileMessage = null;
		const result = await updateUserSettings(settings.id, { displayName, name, language });
		savingProfile = false;
		if (result.success) {
			adopt(result.data);
			profileMessage = { kind: 'ok', text: 'Saved' };
			// The shell shows the display name; resync the lean session user.
			void session.load();
		} else {
			profileMessage = { kind: 'error', text: result.errors[0]?.message ?? 'Could not save' };
		}
	}

	async function submitEmail() {
		if (!settings || savingEmail || newEmail.trim() === '') return;
		savingEmail = true;
		emailMessage = null;
		const result = await requestEmailChange(settings.id, newEmail.trim());
		savingEmail = false;
		if (result.success) {
			settings = result.data;
			newEmail = '';
			emailMessage = {
				kind: 'ok',
				text: 'Check your new inbox for a confirmation link.'
			};
		} else {
			emailMessage = {
				kind: 'error',
				text: result.errors[0]?.message ?? 'Could not request change'
			};
		}
	}

	async function submitPassword() {
		if (!settings || savingPassword) return;
		if (newPassword !== confirmPassword) {
			passwordMessage = { kind: 'error', text: 'Passwords do not match.' };
			return;
		}
		savingPassword = true;
		passwordMessage = null;
		const result = settings.hasPassword
			? await changeUserPassword(settings.id, {
					currentPassword,
					password: newPassword,
					passwordConfirmation: confirmPassword
				})
			: await setUserPassword(settings.id, {
					password: newPassword,
					passwordConfirmation: confirmPassword
				});
		savingPassword = false;
		if (result.success) {
			settings = result.data;
			currentPassword = '';
			newPassword = '';
			confirmPassword = '';
			passwordMessage = { kind: 'ok', text: 'Password updated.' };
		} else {
			passwordMessage = {
				kind: 'error',
				text: result.errors[0]?.message ?? 'Could not update password'
			};
		}
	}
</script>

{#if loading}
	<div class="space-y-4" data-testid="settings-profile-loading">
		{#each [1, 2, 3] as i (i)}
			<div class="h-32 animate-pulse rounded-xl bg-muted/60"></div>
		{/each}
	</div>
{:else if settings}
	<div class="space-y-6" data-testid="settings-profile">
		<SettingsSection title="Avatar" description="Upload an image or generate one with AI.">
			<ProfileImagePicker
				target={{ kind: 'avatar' }}
				currentUrl={session.user?.avatarUrl ?? null}
				onUpdated={() => void session.load()}
			/>
		</SettingsSection>

		<SettingsSection title="Profile" description="How you appear across Magus.">
			<form
				class="space-y-3"
				onsubmit={(event) => {
					event.preventDefault();
					void saveProfile();
				}}
			>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Display name</span>
					<input
						type="text"
						bind:value={displayName}
						maxlength="50"
						placeholder="How you're shown to collaborators"
						data-testid="profile-display-name"
						class={FIELD}
					/>
				</label>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Full name</span>
					<input
						type="text"
						bind:value={name}
						maxlength="100"
						data-testid="profile-name"
						class={FIELD}
					/>
				</label>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Language</span>
					<select bind:value={language} data-testid="profile-language" class={FIELD}>
						<option value="en">English</option>
						<option value="de">Deutsch</option>
					</select>
				</label>
				<div class="flex items-center gap-3 pt-1">
					<Button
						type="submit"
						disabled={!profileDirty || savingProfile}
						data-testid="profile-save"
					>
						{savingProfile ? 'Saving…' : 'Save'}
					</Button>
					{#if profileMessage}
						<span
							class="text-xs {profileMessage.kind === 'ok'
								? 'text-muted-foreground'
								: 'text-destructive'}"
						>
							{profileMessage.text}
						</span>
					{/if}
				</div>
			</form>
		</SettingsSection>

		<SettingsSection title="Email" description="Sign-in address. Changes require confirmation.">
			<div class="mb-3 flex items-center gap-2 text-sm">
				<span class="font-medium">{settings.email}</span>
				{#if settings.pendingEmail}
					<span
						class="rounded-full bg-warning/15 px-2 py-0.5 text-[10px] font-medium text-warning"
						data-testid="profile-pending-email"
					>
						Pending: {settings.pendingEmail}
					</span>
				{/if}
			</div>
			<form
				class="flex items-end gap-2"
				onsubmit={(event) => {
					event.preventDefault();
					void submitEmail();
				}}
			>
				<label class="flex flex-1 flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">New email</span>
					<input
						type="email"
						bind:value={newEmail}
						placeholder="you@example.com"
						data-testid="profile-new-email"
						class={FIELD}
					/>
				</label>
				<Button
					type="submit"
					variant="outline"
					disabled={savingEmail || newEmail.trim() === ''}
					data-testid="profile-request-email"
				>
					{savingEmail ? 'Sending…' : 'Request change'}
				</Button>
			</form>
			{#if emailMessage}
				<p
					class="mt-2 text-xs {emailMessage.kind === 'ok'
						? 'text-muted-foreground'
						: 'text-destructive'}"
				>
					{emailMessage.text}
				</p>
			{/if}
		</SettingsSection>

		<SettingsSection
			title={settings.hasPassword ? 'Change password' : 'Set a password'}
			description={settings.hasPassword
				? 'Update the password you use to sign in.'
				: 'Add a password so you can sign in without a magic link.'}
		>
			<form
				class="space-y-3"
				onsubmit={(event) => {
					event.preventDefault();
					void submitPassword();
				}}
			>
				{#if settings.hasPassword}
					<label class="flex flex-col gap-1.5">
						<span class="text-xs font-medium text-muted-foreground">Current password</span>
						<input
							type="password"
							bind:value={currentPassword}
							autocomplete="current-password"
							data-testid="profile-current-password"
							class={FIELD}
						/>
					</label>
				{/if}
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">New password</span>
					<input
						type="password"
						bind:value={newPassword}
						autocomplete="new-password"
						minlength="8"
						data-testid="profile-new-password"
						class={FIELD}
					/>
				</label>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Confirm new password</span>
					<input
						type="password"
						bind:value={confirmPassword}
						autocomplete="new-password"
						minlength="8"
						data-testid="profile-confirm-password"
						class={FIELD}
					/>
				</label>
				<div class="flex items-center gap-3 pt-1">
					<Button
						type="submit"
						disabled={savingPassword || newPassword.length < 8 || confirmPassword.length < 8}
						data-testid="profile-save-password"
					>
						{savingPassword ? 'Saving…' : settings.hasPassword ? 'Change password' : 'Set password'}
					</Button>
					{#if passwordMessage}
						<span
							class="text-xs {passwordMessage.kind === 'ok'
								? 'text-muted-foreground'
								: 'text-destructive'}"
						>
							{passwordMessage.text}
						</span>
					{/if}
				</div>
			</form>
		</SettingsSection>
	</div>
{/if}
