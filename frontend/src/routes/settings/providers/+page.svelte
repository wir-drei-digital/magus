<script lang="ts">
	import { onMount } from 'svelte';
	import { Pencil, Plus, RefreshCw, Trash2 } from '@lucide/svelte';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import { Section as SettingsSection, Field, ToggleSwitch, confirmAction } from '$lib/components/crud';
	import { CONTROL_CLASS } from '$lib/components/crud/styles';
	import {
		createOwnedProvider,
		destroyOwnedProvider,
		listOwnedProviders,
		updateOwnedProvider,
		validateProviderCredential,
		type ProviderEntry,
		type RpcError
	} from '$lib/ash/api';
	import {
		PROVIDER_TYPES,
		badgeKind,
		requiresBaseUrl,
		type ProviderType
	} from '$lib/components/settings/providers/provider-form';

	// Tailwind classes per badge kind. Kept out of the pure module (which decides
	// the kind) so tests stay structural and never assert on CSS.
	const BADGE_CLASS: Record<ReturnType<typeof badgeKind>, string> = {
		neutral: 'bg-secondary text-muted-foreground',
		success: 'bg-success/15 text-success',
		danger: 'bg-destructive/15 text-destructive',
		warning: 'bg-warning/15 text-warning'
	};

	// Human labels for the validation status (structural badge; copy is not asserted).
	const STATUS_LABEL: Record<ProviderEntry['validationStatus'], string> = {
		pending: 'Not validated',
		valid: 'Valid',
		invalid: 'Invalid key',
		error: 'Check failed'
	};

	// Ash field names that a provider save can surface, mapped to the form control
	// they belong to. SSRF/cap/allowlist errors arrive on base_url/base/req_llm_id.
	const BASE_URL_FIELDS = new Set(['base_url', 'baseUrl', 'base']);
	const TYPE_FIELDS = new Set(['req_llm_id', 'reqLlmId']);

	let providers = $state<ProviderEntry[]>([]);
	let loading = $state(true);
	let loadError = $state<string | null>(null);

	// Per-row busy so one provider's action doesn't disable the whole list.
	let busyId = $state<string | null>(null);

	// Dialog state. `editing` holds the provider being edited, or null on create.
	let dialogOpen = $state(false);
	let editing = $state<ProviderEntry | null>(null);
	let saving = $state(false);
	let saveError = $state<string | null>(null);
	let baseUrlError = $state<string | null>(null);
	let typeError = $state<string | null>(null);

	let name = $state('');
	let providerType = $state<ProviderType>('anthropic');
	// Write-only: never prefilled on edit, empty on edit means "keep existing".
	let apiKey = $state('');
	let baseUrl = $state('');

	const showBaseUrl = $derived(requiresBaseUrl(providerType));
	const dialogTitle = $derived(editing ? 'Edit provider' : 'Add provider');

	onMount(() => void load());

	async function load() {
		loading = true;
		loadError = null;
		const result = await listOwnedProviders();
		if (result.success) {
			providers = result.data;
		} else {
			loadError = result.errors[0]?.message ?? 'Could not load providers';
		}
		loading = false;
	}

	function badgeClassFor(provider: ProviderEntry): string {
		return BADGE_CLASS[badgeKind(provider.validationStatus)];
	}

	function replaceProvider(updated: ProviderEntry) {
		providers = providers.map((p) => (p.id === updated.id ? updated : p));
	}

	function openCreate() {
		editing = null;
		name = '';
		providerType = 'anthropic';
		apiKey = '';
		baseUrl = '';
		clearErrors();
		dialogOpen = true;
	}

	function openEdit(provider: ProviderEntry) {
		editing = provider;
		name = provider.name;
		// req_llm_id is immutable; reflect it in the (disabled) select if it is one
		// of the known types, otherwise fall back to openai_compatible for display.
		providerType = (PROVIDER_TYPES as readonly string[]).includes(provider.reqLlmId)
			? (provider.reqLlmId as ProviderType)
			: 'openai_compatible';
		apiKey = '';
		baseUrl = provider.baseUrl ?? '';
		clearErrors();
		dialogOpen = true;
	}

	function clearErrors() {
		saveError = null;
		baseUrlError = null;
		typeError = null;
	}

	/** Route Ash field errors onto their control; keep the rest as a form error. */
	function applyErrors(errors: RpcError[]) {
		clearErrors();
		const leftover: RpcError[] = [];
		for (const err of errors) {
			const fields = err.fields ?? [];
			if (fields.some((f) => BASE_URL_FIELDS.has(f))) {
				baseUrlError = err.message;
			} else if (fields.some((f) => TYPE_FIELDS.has(f))) {
				typeError = err.message;
			} else {
				leftover.push(err);
			}
		}
		if (leftover.length > 0 || (!baseUrlError && !typeError)) {
			saveError = leftover[0]?.message ?? errors[0]?.message ?? 'Could not save provider';
		}
	}

	async function save() {
		if (saving || name.trim() === '') return;
		saving = true;
		clearErrors();

		const trimmedBaseUrl = baseUrl.trim();
		const trimmedKey = apiKey.trim();

		const result = editing
			? await updateOwnedProvider(editing.id, {
					name: name.trim(),
					...(showBaseUrl ? { baseUrl: trimmedBaseUrl || null } : {}),
					// Empty on edit means "do not send the field" (keep existing key).
					...(trimmedKey !== '' ? { apiKey: trimmedKey } : {})
				})
			: await createOwnedProvider({
					name: name.trim(),
					reqLlmId: providerType,
					...(showBaseUrl ? { baseUrl: trimmedBaseUrl || null } : {}),
					...(trimmedKey !== '' ? { apiKey: trimmedKey } : {})
				});

		if (!result.success) {
			saving = false;
			applyErrors(result.errors);
			return;
		}

		const provider = result.data;
		if (editing) replaceProvider(provider);
		else providers = [provider, ...providers];

		saving = false;
		dialogOpen = false;
	}

	async function toggle(provider: ProviderEntry) {
		if (busyId) return;
		busyId = provider.id;
		const result = await updateOwnedProvider(provider.id, { enabled: !provider.enabled });
		if (result.success) replaceProvider(result.data);
		busyId = null;
	}

	async function revalidate(provider: ProviderEntry) {
		if (busyId) return;
		busyId = provider.id;
		const result = await validateProviderCredential(provider.id);
		if (result.success) {
			replaceProvider(result.data);
		} else {
			// Refetch so the row reflects whatever the server recorded.
			await load();
		}
		busyId = null;
	}

	async function remove(provider: ProviderEntry) {
		const confirmed = await confirmAction({
			title: 'Delete provider?',
			description: 'Models that use this provider will stop working.',
			confirmLabel: 'Delete'
		});
		if (!confirmed || busyId) return;
		busyId = provider.id;
		const result = await destroyOwnedProvider(provider.id);
		if (result.success) {
			providers = providers.filter((p) => p.id !== provider.id);
		}
		busyId = null;
	}
</script>

{#if loading}
	<div class="space-y-2" data-testid="settings-providers-loading">
		{#each [1, 2, 3] as i (i)}
			<div class="h-16 animate-pulse rounded-lg bg-muted/60"></div>
		{/each}
	</div>
{:else}
	<div class="space-y-6" data-testid="settings-providers">
		<SettingsSection
			title="Providers"
			description="Bring your own API keys. Add a model provider and Magus routes matching models through your account. Keys are stored encrypted and never shown again."
		>
			<div class="mb-3">
				<Button onclick={openCreate} data-testid="provider-add-button">
					<Plus class="size-4" />
					Add provider
				</Button>
			</div>

			{#if loadError}
				<p class="mb-3 text-xs text-destructive" data-testid="provider-error">{loadError}</p>
			{/if}

			{#if providers.length === 0}
				<div
					class="rounded-lg border border-dashed py-8 text-center"
					data-testid="provider-empty"
				>
					<p class="text-sm text-muted-foreground">No providers yet.</p>
					<p class="mx-auto mt-1 max-w-sm text-xs text-muted-foreground">
						Add your own provider key (Anthropic, OpenAI, and more) to run models on your own
						account instead of shared credits.
					</p>
				</div>
			{:else}
				<ul class="divide-y" data-testid="provider-list">
					{#each providers as provider (provider.id)}
						<li class="flex items-center gap-3 py-3 first:pt-0 last:pb-0" data-testid="provider-card">
							<div class="min-w-0 flex-1">
								<p class="flex items-center gap-2 text-sm font-medium">
									<span class="truncate">{provider.name}</span>
									<span
										class="shrink-0 rounded-full bg-secondary px-1.5 py-0.5 font-mono text-[10px] font-medium text-muted-foreground uppercase"
									>
										{provider.reqLlmId}
									</span>
									<span
										class="shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-medium {badgeClassFor(
											provider
										)}"
										data-testid="provider-validation-badge"
									>
										{STATUS_LABEL[provider.validationStatus]}
									</span>
								</p>
								<p class="truncate text-xs text-muted-foreground">
									Key set{#if provider.baseUrl}
										· <code class="font-mono">{provider.baseUrl}</code>{/if}
								</p>
							</div>
							<ToggleSwitch
								checked={provider.enabled}
								disabled={busyId === provider.id}
								label={provider.enabled ? 'Disable provider' : 'Enable provider'}
								testid="provider-enabled-toggle"
								onchange={() => void toggle(provider)}
							/>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0"
								title="Re-validate"
								data-testid="provider-revalidate-button"
								disabled={busyId === provider.id}
								onclick={() => void revalidate(provider)}
							>
								<RefreshCw class="size-3.5 {busyId === provider.id ? 'animate-spin' : ''}" />
							</button>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0"
								title="Edit"
								data-testid="provider-edit-button"
								onclick={() => openEdit(provider)}
							>
								<Pencil class="size-3.5" />
							</button>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0 hover:!text-destructive"
								title="Delete"
								data-testid="provider-delete-button"
								disabled={busyId === provider.id}
								onclick={() => void remove(provider)}
							>
								<Trash2 class="size-3.5" />
							</button>
						</li>
					{/each}
				</ul>
			{/if}
		</SettingsSection>
	</div>
{/if}

<Dialog.Root bind:open={dialogOpen}>
	<Dialog.Content class="sm:max-w-md" data-testid="provider-dialog">
		<Dialog.Header>
			<Dialog.Title>{dialogTitle}</Dialog.Title>
			<Dialog.Description>
				Provider keys are stored encrypted and validated in the background.
			</Dialog.Description>
		</Dialog.Header>
		<form
			class="space-y-3"
			data-testid="provider-form"
			onsubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<Field label="Type" testid="provider-type-field" error={typeError} required>
				<select
					bind:value={providerType}
					disabled={!!editing}
					data-testid="provider-type-input"
					class={CONTROL_CLASS}
				>
					{#each PROVIDER_TYPES as type (type)}
						<option value={type}>{type}</option>
					{/each}
				</select>
			</Field>

			<Field label="Name" testid="provider-name-field" required>
				<input
					type="text"
					bind:value={name}
					maxlength="100"
					placeholder="e.g. My Anthropic key"
					data-testid="provider-name-input"
					class={CONTROL_CLASS}
				/>
			</Field>

			{#if showBaseUrl}
				<Field
					label="Base URL"
					testid="provider-base-url-field"
					error={baseUrlError}
					hint="Required for OpenAI-compatible endpoints."
				>
					<input
						type="url"
						bind:value={baseUrl}
						placeholder="https://api.example.com/v1"
						data-testid="provider-base-url-input"
						class={CONTROL_CLASS}
					/>
				</Field>
			{/if}

			<Field
				label="API key"
				testid="provider-api-key-field"
				hint={editing ? 'Leave blank to keep the existing key.' : 'Stored encrypted; never shown again.'}
			>
				<input
					type="password"
					bind:value={apiKey}
					autocomplete="off"
					placeholder={editing ? 'Leave blank to keep existing' : 'Paste key'}
					data-testid="provider-api-key-input"
					class="{CONTROL_CLASS} font-mono"
				/>
			</Field>

			{#if saveError}
				<p class="text-xs text-destructive" data-testid="provider-save-error">{saveError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (dialogOpen = false)}>Cancel</Button>
				<Button
					type="submit"
					disabled={saving || name.trim() === ''}
					data-testid="provider-save-button"
				>
					{saving ? 'Saving…' : editing ? 'Save' : 'Add provider'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
