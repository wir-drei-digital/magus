<script lang="ts">
	import { onMount } from 'svelte';
	import { ChevronDown, ChevronRight, Pencil, Plus, RefreshCw, Trash2 } from '@lucide/svelte';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import {
		Section as SettingsSection,
		Field,
		ToggleSwitch,
		confirmAction
	} from '$lib/components/crud';
	import { CONTROL_CLASS } from '$lib/components/crud/styles';
	import {
		createOwnedModel,
		createOwnedProvider,
		destroyOwnedModel,
		destroyOwnedProvider,
		listOwnedModels,
		listOwnedProviders,
		listRemoteModels,
		updateOwnedProvider,
		validateProviderCredential,
		type OwnedModelEntry,
		type ProviderEntry,
		type RpcError
	} from '$lib/ash/api';
	import {
		PROVIDER_TYPES,
		badgeKind,
		requiresBaseUrl,
		type ProviderType
	} from '$lib/components/settings/providers/provider-form';
	import {
		filterModelIds,
		modelsForProvider,
		pickerMode,
		type RemoteListStatus
	} from '$lib/components/settings/providers/model-picker';

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

	// Ash field names a model save can surface, mapped to the control they belong
	// to. Media-block errors arrive on output_modalities; the per-user cap on base.
	const MODEL_ID_FIELDS = new Set(['model_id', 'modelId']);
	const MODEL_NAME_FIELDS = new Set(['name']);

	let providers = $state<ProviderEntry[]>([]);
	let loading = $state(true);
	let loadError = $state<string | null>(null);

	// All owned models across every provider; grouped per card client-side.
	let ownedModels = $state<OwnedModelEntry[]>([]);

	// Per-row busy so one provider's action doesn't disable the whole list.
	let busyId = $state<string | null>(null);

	// Which provider card has its models section expanded (only one at a time).
	let expandedId = $state<string | null>(null);
	// Per-model busy so one delete doesn't disable the whole models section.
	let busyModelId = $state<string | null>(null);

	// Add-model dialog state, scoped to the provider it was opened from.
	let modelDialogOpen = $state(false);
	let modelProvider = $state<ProviderEntry | null>(null);
	let modelSaving = $state(false);
	let modelSaveError = $state<string | null>(null);
	let modelIdError = $state<string | null>(null);
	let modelNameError = $state<string | null>(null);

	// Remote-probe results driving the id picker. `manual` forces free-text even
	// when a picker listing is available ("type it manually" toggle).
	let remoteStatus = $state<RemoteListStatus>('unavailable');
	let remoteIds = $state<string[]>([]);
	let remoteLoading = $state(false);
	let manualEntry = $state(false);

	let modelId = $state('');
	let modelName = $state('');
	let modelIdQuery = $state('');
	let contextWindow = $state('');
	let inputCost = $state('');
	let outputCost = $state('');

	const effectiveMode = $derived<'picker' | 'freetext'>(
		manualEntry ? 'freetext' : pickerMode(remoteStatus, remoteIds)
	);
	const filteredIds = $derived(filterModelIds(remoteIds, modelIdQuery));

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
		const [providersResult, modelsResult] = await Promise.all([
			listOwnedProviders(),
			listOwnedModels()
		]);
		if (providersResult.success) {
			providers = providersResult.data;
		} else {
			loadError = providersResult.errors[0]?.message ?? 'Could not load providers';
		}
		// A model-list failure degrades softly: providers still render, sections
		// just show no rows until the next refetch succeeds.
		if (modelsResult.success) ownedModels = modelsResult.data;
		loading = false;
	}

	async function refetchModels() {
		const result = await listOwnedModels();
		if (result.success) ownedModels = result.data;
	}

	function modelsFor(provider: ProviderEntry): OwnedModelEntry[] {
		return modelsForProvider(ownedModels, provider.id);
	}

	function toggleExpanded(provider: ProviderEntry) {
		expandedId = expandedId === provider.id ? null : provider.id;
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
		const cascading = modelsFor(provider);
		const description =
			cascading.length === 0
				? 'Models that use this provider will stop working.'
				: `Deleting this provider also deletes ${cascading.length} model${
						cascading.length === 1 ? '' : 's'
					}: ${cascading.map((m) => m.name).join(', ')}.`;
		const confirmed = await confirmAction({
			title: 'Delete provider?',
			description,
			confirmLabel: 'Delete'
		});
		if (!confirmed || busyId) return;
		busyId = provider.id;
		const result = await destroyOwnedProvider(provider.id);
		if (result.success) {
			providers = providers.filter((p) => p.id !== provider.id);
			if (expandedId === provider.id) expandedId = null;
			// Its models cascaded server-side; drop them from the grouped list too.
			ownedModels = ownedModels.filter((m) => m.modelProviderId !== provider.id);
		}
		busyId = null;
	}

	// ─── Owned models ──────────────────────────────────────────────────────────

	function clearModelErrors() {
		modelSaveError = null;
		modelIdError = null;
		modelNameError = null;
	}

	/** Route Ash field errors onto their control; keep the rest as a form error. */
	function applyModelErrors(errors: RpcError[]) {
		clearModelErrors();
		const leftover: RpcError[] = [];
		for (const err of errors) {
			const fields = err.fields ?? [];
			if (fields.some((f) => MODEL_ID_FIELDS.has(f))) {
				modelIdError = err.message;
			} else if (fields.some((f) => MODEL_NAME_FIELDS.has(f))) {
				modelNameError = err.message;
			} else {
				// Cap (base) + media-block (output_modalities) errors land here.
				leftover.push(err);
			}
		}
		if (leftover.length > 0 || (!modelIdError && !modelNameError)) {
			modelSaveError = leftover[0]?.message ?? errors[0]?.message ?? 'Could not add model';
		}
	}

	async function openAddModel(provider: ProviderEntry) {
		modelProvider = provider;
		modelId = '';
		modelName = '';
		modelIdQuery = '';
		contextWindow = '';
		inputCost = '';
		outputCost = '';
		manualEntry = false;
		remoteIds = [];
		remoteStatus = 'unavailable';
		clearModelErrors();
		modelDialogOpen = true;

		// Probe the provider so the picker knows whether to offer a select. A soft
		// failure just leaves us in free-text mode.
		remoteLoading = true;
		const result = await listRemoteModels(provider.id);
		if (result.success) {
			remoteStatus = result.data.status;
			remoteIds = result.data.modelIds;
		}
		remoteLoading = false;
	}

	function chooseModelId(id: string) {
		modelId = id;
		modelIdQuery = id;
	}

	async function saveModel() {
		if (modelSaving || !modelProvider) return;
		if (modelId.trim() === '' || modelName.trim() === '') return;
		modelSaving = true;
		clearModelErrors();

		const ctx = contextWindow.trim() === '' ? null : Number(contextWindow);
		const inCost = inputCost.trim() === '' ? null : Number(inputCost);
		const outCost = outputCost.trim() === '' ? null : Number(outputCost);

		const result = await createOwnedModel({
			modelId: modelId.trim(),
			name: modelName.trim(),
			modelProviderId: modelProvider.id,
			...(ctx != null && !Number.isNaN(ctx) ? { contextWindow: ctx } : {}),
			...(inCost != null && !Number.isNaN(inCost) ? { inputCostValue: inCost } : {}),
			...(outCost != null && !Number.isNaN(outCost) ? { outputCostValue: outCost } : {})
		});

		if (!result.success) {
			modelSaving = false;
			applyModelErrors(result.errors);
			return;
		}

		await refetchModels();
		modelSaving = false;
		modelDialogOpen = false;
	}

	async function removeModel(model: OwnedModelEntry) {
		const confirmed = await confirmAction({
			title: 'Delete model?',
			description: `${model.name} will be removed from your account.`,
			confirmLabel: 'Delete'
		});
		if (!confirmed || busyModelId) return;
		busyModelId = model.id;
		const result = await destroyOwnedModel(model.id);
		if (result.success) {
			ownedModels = ownedModels.filter((m) => m.id !== model.id);
		}
		busyModelId = null;
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
				<div class="rounded-lg border border-dashed py-8 text-center" data-testid="provider-empty">
					<p class="text-sm text-muted-foreground">No providers yet.</p>
					<p class="mx-auto mt-1 max-w-sm text-xs text-muted-foreground">
						Add your own provider key (Anthropic, OpenAI, and more) to run models on your own
						account instead of shared credits.
					</p>
				</div>
			{:else}
				<ul class="divide-y" data-testid="provider-list">
					{#each providers as provider (provider.id)}
						<li class="py-3 first:pt-0 last:pb-0" data-testid="provider-card">
							<div class="flex items-center gap-3">
								<button
									type="button"
									class="wb-pill-btn wb-pill-btn-square shrink-0"
									title={expandedId === provider.id ? 'Hide models' : 'Show models'}
									aria-expanded={expandedId === provider.id}
									data-testid="provider-expand-button"
									onclick={() => toggleExpanded(provider)}
								>
									{#if expandedId === provider.id}
										<ChevronDown class="size-3.5" />
									{:else}
										<ChevronRight class="size-3.5" />
									{/if}
								</button>
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
										Key set · {modelsFor(provider).length} model{modelsFor(provider).length === 1
											? ''
											: 's'}{#if provider.baseUrl}
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
							</div>

							{#if expandedId === provider.id}
								<div
									class="mt-3 ml-9 rounded-lg border bg-muted/30 p-3"
									data-testid="provider-models-section"
								>
									<div class="mb-2 flex items-center justify-between">
										<p class="text-xs font-medium text-muted-foreground">Models</p>
										<Button
											variant="ghost"
											size="sm"
											onclick={() => void openAddModel(provider)}
											data-testid="model-add-button"
										>
											<Plus class="size-3.5" />
											Add model
										</Button>
									</div>

									{#if modelsFor(provider).length === 0}
										<p class="py-2 text-xs text-muted-foreground" data-testid="model-empty">
											No models yet. Add one to route it through this provider.
										</p>
									{:else}
										<ul class="divide-y">
											{#each modelsFor(provider) as model (model.id)}
												<li
													class="flex items-center gap-3 py-2 first:pt-0 last:pb-0"
													data-testid="model-row"
												>
													<div class="min-w-0 flex-1">
														<p class="truncate text-sm font-medium">{model.name}</p>
														<p class="truncate text-xs text-muted-foreground">
															{#if model.contextWindow}{model.contextWindow.toLocaleString()} ctx{/if}
															{#if model.inputCost}· in {model.inputCost}{/if}
															{#if model.outputCost}· out {model.outputCost}{/if}
														</p>
													</div>
													<button
														type="button"
														class="wb-pill-btn wb-pill-btn-square shrink-0 hover:!text-destructive"
														title="Delete model"
														data-testid="model-delete-button"
														disabled={busyModelId === model.id}
														onclick={() => void removeModel(model)}
													>
														<Trash2 class="size-3.5" />
													</button>
												</li>
											{/each}
										</ul>
									{/if}
								</div>
							{/if}
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
				hint={editing
					? 'Leave blank to keep the existing key.'
					: 'Stored encrypted; never shown again.'}
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

<Dialog.Root bind:open={modelDialogOpen}>
	<Dialog.Content class="sm:max-w-md" data-testid="model-dialog">
		<Dialog.Header>
			<Dialog.Title>Add model</Dialog.Title>
			<Dialog.Description>
				{#if modelProvider}
					A text model served by {modelProvider.name}. Pick an id it advertises or type one
					manually.
				{:else}
					Pick a model id or type one manually.
				{/if}
			</Dialog.Description>
		</Dialog.Header>
		<form
			class="space-y-3"
			data-testid="model-form"
			onsubmit={(event) => {
				event.preventDefault();
				void saveModel();
			}}
		>
			<Field label="Model id" testid="model-id-field" error={modelIdError} required>
				{#if effectiveMode === 'picker'}
					<div class="space-y-1.5" data-testid="model-id-picker">
						<input
							type="text"
							bind:value={modelIdQuery}
							oninput={() => (modelId = modelIdQuery)}
							placeholder="Search advertised models"
							data-testid="model-id-search"
							class={CONTROL_CLASS}
						/>
						<select
							bind:value={modelId}
							onchange={() => (modelIdQuery = modelId)}
							size="6"
							data-testid="model-id-select"
							class={CONTROL_CLASS}
						>
							{#each filteredIds as id (id)}
								<option value={id}>{id}</option>
							{/each}
						</select>
					</div>
				{:else}
					<input
						type="text"
						bind:value={modelId}
						oninput={() => chooseModelId(modelId)}
						placeholder="e.g. claude-sonnet-4-20250514"
						data-testid="model-id-freetext"
						class="{CONTROL_CLASS} font-mono"
					/>
				{/if}
			</Field>

			<div class="flex items-center justify-between text-xs">
				{#if remoteLoading}
					<span class="text-muted-foreground" data-testid="model-probe-loading"
						>Loading models…</span
					>
				{:else}
					<span></span>
				{/if}
				{#if pickerMode(remoteStatus, remoteIds) === 'picker'}
					<button
						type="button"
						class="text-muted-foreground underline underline-offset-2 hover:text-foreground"
						data-testid="model-manual-toggle"
						onclick={() => (manualEntry = !manualEntry)}
					>
						{manualEntry ? 'Pick from list' : 'Type it manually'}
					</button>
				{/if}
			</div>

			<Field label="Display name" testid="model-name-field" error={modelNameError} required>
				<input
					type="text"
					bind:value={modelName}
					maxlength="100"
					placeholder="e.g. Claude Sonnet 4"
					data-testid="model-name-input"
					class={CONTROL_CLASS}
				/>
			</Field>

			<Field label="Context window" testid="model-context-field" hint="Optional, in tokens.">
				<input
					type="number"
					min="0"
					bind:value={contextWindow}
					placeholder="e.g. 200000"
					data-testid="model-context-input"
					class={CONTROL_CLASS}
				/>
			</Field>

			<div class="grid grid-cols-2 gap-3">
				<Field label="Input cost" testid="model-input-cost-field" hint="Per 1M tokens.">
					<input
						type="number"
						min="0"
						step="0.01"
						bind:value={inputCost}
						placeholder="e.g. 3"
						data-testid="model-input-cost-input"
						class={CONTROL_CLASS}
					/>
				</Field>
				<Field label="Output cost" testid="model-output-cost-field" hint="Per 1M tokens.">
					<input
						type="number"
						min="0"
						step="0.01"
						bind:value={outputCost}
						placeholder="e.g. 15"
						data-testid="model-output-cost-input"
						class={CONTROL_CLASS}
					/>
				</Field>
			</div>

			{#if modelSaveError}
				<p class="text-xs text-destructive" data-testid="model-save-error">{modelSaveError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (modelDialogOpen = false)}>
					Cancel
				</Button>
				<Button
					type="submit"
					disabled={modelSaving || modelId.trim() === '' || modelName.trim() === ''}
					data-testid="model-save-button"
				>
					{modelSaving ? 'Saving…' : 'Add model'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
