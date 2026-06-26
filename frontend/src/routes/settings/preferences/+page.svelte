<script lang="ts">
	import { onMount } from 'svelte';
	import { Button } from '$lib/components/ui/button';
	import { Section as SettingsSection, CONTROL_CLASS } from '$lib/components/crud';
	import ToggleSwitch from '$lib/components/crud/toggle-switch.svelte';
	import { confirmAction } from '$lib/stores/confirm.svelte';
	import {
		grantDataRegionConsent,
		listActiveModels,
		listImageGenerationModels,
		listVideoGenerationModels,
		selectDefaultImageModel,
		selectDefaultModel,
		selectDefaultVideoModel,
		updateDataRegionPreference,
		updateTimezone,
		userSettings,
		type ModelSummary,
		type UserSettings
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';

	// Mirrors config/config.exs :magus :regions. Consent-gated regions record a
	// timestamp before they can be enabled.
	const DATA_REGIONS = [
		{ code: 'US', label: 'United States', consent: false },
		{ code: 'EU', label: 'Europe', consent: false },
		{ code: 'CH', label: 'Switzerland', consent: false },
		{ code: 'CN', label: 'China', consent: true },
		{ code: 'SG', label: 'Singapore', consent: true }
	];

	const enabledRegions = $derived(session.user?.dataRegionPreference ?? []);
	const regionConsents = $derived(session.user?.dataRegionConsents ?? {});
	let regionBusy = $state(false);
	let regionError = $state<string | null>(null);

	async function toggleRegion(code: string, enable: boolean) {
		const userId = session.user?.id;
		if (!userId || regionBusy) return;
		regionBusy = true;
		regionError = null;

		const region = DATA_REGIONS.find((entry) => entry.code === code);
		let result;
		if (enable && region?.consent && !regionConsents[code]) {
			const ok = await confirmAction({
				title: `Enable ${region.label}?`,
				description: 'This consents to processing your data in that region.',
				confirmLabel: 'Enable',
				destructive: false
			});
			if (!ok) {
				regionBusy = false;
				return;
			}
			result = await grantDataRegionConsent(userId, code);
		} else {
			const next = enable
				? [...enabledRegions, code]
				: enabledRegions.filter((entry) => entry !== code);
			result = await updateDataRegionPreference(userId, next);
		}

		regionBusy = false;
		if (result.success) {
			await session.load();
		} else {
			regionError = result.errors[0]?.message ?? 'Could not update data regions';
		}
	}

	const FIELD = CONTROL_CLASS;
	const TZ_LOCK_DAYS = 30;

	let settings = $state<UserSettings | null>(null);
	let chatModels = $state<ModelSummary[]>([]);
	let imageModels = $state<ModelSummary[]>([]);
	let videoModels = $state<ModelSummary[]>([]);
	let loading = $state(true);

	let timezone = $state('');
	let savingTimezone = $state(false);
	let timezoneMessage = $state<{ kind: 'ok' | 'error'; text: string } | null>(null);

	// Toggles live in ui_preferences; classic parity on key + default.
	const autoscroll = $derived(session.user?.uiPreferences?.['autoscroll_enabled'] !== false);
	const tabsEnabled = $derived(session.user?.uiPreferences?.['tabs_enabled'] === true);

	// Timezone is rate-limited server-side to one change per 30 days.
	const tzDaysRemaining = $derived.by(() => {
		if (!settings?.lastTimezoneChangeAt) return 0;
		const changed = new Date(settings.lastTimezoneChangeAt).getTime();
		const elapsed = (Date.now() - changed) / 86_400_000;
		return Math.max(0, Math.ceil(TZ_LOCK_DAYS - elapsed));
	});
	const tzLocked = $derived(tzDaysRemaining > 0);
	const tzDirty = $derived(settings !== null && timezone.trim() !== (settings.timezone ?? ''));

	onMount(() => {
		void load();
	});

	async function load() {
		const [s, chat, image, video] = await Promise.all([
			userSettings(),
			listActiveModels(),
			listImageGenerationModels(),
			listVideoGenerationModels()
		]);
		if (s.success) {
			settings = s.data;
			timezone = s.data.timezone ?? '';
		}
		if (chat.success) chatModels = chat.data;
		if (image.success) imageModels = image.data;
		if (video.success) videoModels = video.data;
		loading = false;
	}

	async function pickChatModel(id: string) {
		if (!settings) return;
		const result = await selectDefaultModel(settings.id, id || null);
		if (result.success) settings = result.data;
	}

	async function pickImageModel(id: string) {
		if (!settings) return;
		const result = await selectDefaultImageModel(settings.id, id || null);
		if (result.success) settings = result.data;
	}

	async function pickVideoModel(id: string) {
		if (!settings) return;
		const result = await selectDefaultVideoModel(settings.id, id || null);
		if (result.success) settings = result.data;
	}

	async function saveTimezone() {
		if (!settings || savingTimezone || !tzDirty) return;
		savingTimezone = true;
		timezoneMessage = null;
		const result = await updateTimezone(settings.id, timezone.trim());
		savingTimezone = false;
		if (result.success) {
			settings = result.data;
			timezone = result.data.timezone ?? '';
			timezoneMessage = { kind: 'ok', text: 'Saved' };
		} else {
			timezoneMessage = { kind: 'error', text: result.errors[0]?.message ?? 'Could not save' };
		}
	}
</script>

{#if loading}
	<div class="space-y-4" data-testid="settings-preferences-loading">
		{#each [1, 2, 3] as i (i)}
			<div class="h-32 animate-pulse rounded-xl bg-muted/60"></div>
		{/each}
	</div>
{:else if settings}
	<div class="space-y-6" data-testid="settings-preferences">
		<SettingsSection
			title="Default models"
			description="The model each new conversation starts with. Auto lets the router choose."
		>
			<div class="space-y-3">
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Chat</span>
					<select
						value={settings.selectedModelId ?? ''}
						onchange={(event) => void pickChatModel(event.currentTarget.value)}
						data-testid="default-chat-model"
						class={FIELD}
					>
						<option value="">Auto</option>
						{#each chatModels as model (model.id)}
							<option value={model.id}>{model.name}</option>
						{/each}
					</select>
				</label>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Image generation</span>
					<select
						value={settings.selectedImageModelId ?? ''}
						onchange={(event) => void pickImageModel(event.currentTarget.value)}
						data-testid="default-image-model"
						class={FIELD}
					>
						<option value="">Auto</option>
						{#each imageModels as model (model.id)}
							<option value={model.id}>{model.name}</option>
						{/each}
					</select>
				</label>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Video generation</span>
					<select
						value={settings.selectedVideoModelId ?? ''}
						onchange={(event) => void pickVideoModel(event.currentTarget.value)}
						data-testid="default-video-model"
						class={FIELD}
					>
						<option value="">Auto</option>
						{#each videoModels as model (model.id)}
							<option value={model.id}>{model.name}</option>
						{/each}
					</select>
				</label>
			</div>
		</SettingsSection>

		<SettingsSection title="Timezone" description="Used for scheduling and time display.">
			<form
				class="flex items-end gap-2"
				onsubmit={(event) => {
					event.preventDefault();
					void saveTimezone();
				}}
			>
				<label class="flex flex-1 flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">IANA timezone</span>
					<input
						type="text"
						bind:value={timezone}
						disabled={tzLocked}
						placeholder="America/New_York"
						data-testid="preferences-timezone"
						class="{FIELD} disabled:opacity-60"
					/>
				</label>
				<Button
					type="submit"
					variant="outline"
					disabled={tzLocked || savingTimezone || !tzDirty}
					data-testid="preferences-save-timezone"
				>
					{savingTimezone ? 'Saving…' : 'Save'}
				</Button>
			</form>
			{#if tzLocked}
				<p class="mt-2 text-xs text-muted-foreground" data-testid="preferences-timezone-locked">
					You can change your timezone again in {tzDaysRemaining}
					{tzDaysRemaining === 1 ? 'day' : 'days'}.
				</p>
			{:else if timezoneMessage}
				<p
					class="mt-2 text-xs {timezoneMessage.kind === 'ok'
						? 'text-muted-foreground'
						: 'text-destructive'}"
				>
					{timezoneMessage.text}
				</p>
			{/if}
		</SettingsSection>

		<SettingsSection title="Interface" description="How the workbench behaves.">
			<div class="divide-y">
				<div class="flex items-center justify-between py-3 first:pt-0">
					<div class="pr-4">
						<p class="text-sm font-medium">Autoscroll while streaming</p>
						<p class="text-xs text-muted-foreground">
							Follow the latest tokens as the assistant replies.
						</p>
					</div>
					<ToggleSwitch
						checked={autoscroll}
						label="Autoscroll while streaming"
						testid="preferences-autoscroll"
						onchange={(next) => void session.setUiPreference('autoscroll_enabled', next)}
					/>
				</div>
				<div class="flex items-center justify-between py-3 last:pb-0">
					<div class="pr-4">
						<p class="text-sm font-medium">Show tabs</p>
						<p class="text-xs text-muted-foreground">
							Keep a tab bar for open conversations and pages.
						</p>
					</div>
					<ToggleSwitch
						checked={tabsEnabled}
						label="Show tabs"
						testid="preferences-tabs"
						onchange={(next) => void session.setUiPreference('tabs_enabled', next)}
					/>
				</div>
			</div>
		</SettingsSection>

		<SettingsSection
			title="Data region"
			description="Regions your data may be processed in for model routing. At least one is required."
		>
			{#if regionError}
				<p class="mb-2 text-xs text-destructive" data-testid="data-region-error">{regionError}</p>
			{/if}
			<div class="divide-y">
				{#each DATA_REGIONS as region (region.code)}
					<div class="flex items-center justify-between py-3 first:pt-0 last:pb-0">
						<div class="pr-4">
							<p class="text-sm font-medium">{region.label}</p>
							<p class="text-xs text-muted-foreground">
								{region.code}{#if region.consent}
									· requires consent{/if}
							</p>
						</div>
						<ToggleSwitch
							checked={enabledRegions.includes(region.code)}
							label={region.label}
							testid="data-region-{region.code}"
							onchange={(next) => void toggleRegion(region.code, next)}
						/>
					</div>
				{/each}
			</div>
		</SettingsSection>
	</div>
{/if}
