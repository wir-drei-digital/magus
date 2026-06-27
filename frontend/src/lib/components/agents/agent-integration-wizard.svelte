<script lang="ts">
	import { base } from '$app/paths';
	import { Copy, ExternalLink, Loader2, Plug } from '@lucide/svelte';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import {
		availableIntegrationProviders,
		connectAgentIntegration,
		type IntegrationProviderMeta
	} from '$lib/ash/api';

	let {
		open = $bindable(false),
		agentId,
		connectedKeys = [],
		onConnected
	}: {
		open?: boolean;
		agentId: string;
		/** Provider keys already connected to this agent (hidden from the picker). */
		connectedKeys?: string[];
		onConnected?: () => void;
	} = $props();

	type Step = 'provider' | 'auth' | 'done';
	let step = $state<Step>('provider');
	let providers = $state<IntegrationProviderMeta[]>([]);
	let loadingProviders = $state(false);
	let provider = $state<IntegrationProviderMeta | null>(null);
	let formValues = $state<Record<string, string>>({});
	let busy = $state(false);
	let error = $state<string | null>(null);
	let apiKey = $state<string | null>(null);
	let copied = $state(false);

	$effect(() => {
		if (!open) return;
		step = 'provider';
		provider = null;
		formValues = {};
		busy = false;
		error = null;
		apiKey = null;
		copied = false;
		void loadProviders();
	});

	async function loadProviders() {
		loadingProviders = true;
		const result = await availableIntegrationProviders(agentId);
		loadingProviders = false;
		if (result.success) providers = result.data;
		else error = result.errors[0]?.message ?? 'Could not load providers.';
	}

	const connectable = $derived(providers.filter((p) => !connectedKeys.includes(p.key)));

	function pickProvider(p: IntegrationProviderMeta) {
		provider = p;
		formValues = {};
		error = null;
		if (p.authType === 'none' || p.authType === 'webhook_only') {
			void connect(p, {});
		} else {
			step = 'auth';
		}
	}

	async function connect(p: IntegrationProviderMeta, credentials: Record<string, string>) {
		busy = true;
		error = null;
		const result = await connectAgentIntegration({ agentId, providerKey: p.key, credentials });
		busy = false;
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Could not connect.';
			// Auto-connect providers have no form to fall back to — return to the picker.
			if (p.authType === 'none' || p.authType === 'webhook_only') step = 'provider';
			return;
		}
		onConnected?.();
		apiKey = result.data.apiKey;
		step = 'done';
	}

	function submitForm() {
		if (provider) void connect(provider, { ...formValues });
	}

	// OAuth: create the integration first (the callback fills its credential),
	// then full-page redirect to the provider's authorize endpoint. On return the
	// agent page reopens at ?section=integrations and reloads the list.
	async function connectOauth() {
		if (!provider) return;
		busy = true;
		error = null;
		const result = await connectAgentIntegration({ agentId, providerKey: provider.key });
		busy = false;
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Could not start the connection.';
			return;
		}
		onConnected?.();
		const returnTo = `${base}/agents/${agentId}?section=integrations`;
		window.location.href = `/oauth/${provider.key}/authorize?return_to=${encodeURIComponent(returnTo)}`;
	}

	async function copyKey() {
		if (!apiKey) return;
		await navigator.clipboard.writeText(apiKey);
		copied = true;
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="max-w-lg">
		<Dialog.Header>
			<Dialog.Title>
				{#if step === 'provider'}
					Connect an integration
				{:else if step === 'auth' && provider}
					Connect {provider.name}
				{:else}
					Connected
				{/if}
			</Dialog.Title>
		</Dialog.Header>

		{#if error}
			<p class="text-sm text-destructive" data-testid="integration-wizard-error">{error}</p>
		{/if}

		{#if step === 'provider'}
			{#if loadingProviders}
				<div class="flex items-center gap-2 p-3 text-sm text-muted-foreground">
					<Loader2 class="size-4 animate-spin" />
					Loading…
				</div>
			{:else if connectable.length === 0}
				<p class="p-3 text-sm text-muted-foreground">
					All available integrations are already connected.
				</p>
			{:else}
				<div class="grid grid-cols-2 gap-2" data-testid="integration-provider-picker">
					{#each connectable as p (p.key)}
						<button
							type="button"
							class="flex flex-col gap-1 rounded-lg border border-input p-3 text-left transition-colors hover:border-primary/60 hover:bg-accent/40 disabled:opacity-50"
							data-testid="integration-provider-option"
							disabled={busy}
							onclick={() => pickProvider(p)}
						>
							<span class="flex items-center gap-2 text-sm font-medium">
								<Plug class="size-4 text-muted-foreground" />
								{p.name}
							</span>
							<span class="text-xs text-muted-foreground">{p.description}</span>
						</button>
					{/each}
				</div>
			{/if}
		{:else if step === 'auth' && provider}
			<div class="flex flex-col gap-3">
				{#if provider.authType === 'oauth2'}
					<p class="text-sm text-muted-foreground">{provider.description}</p>
					<Button
						size="sm"
						class="w-fit"
						disabled={busy}
						onclick={connectOauth}
						data-testid="integration-oauth-connect"
					>
						<ExternalLink class="size-4" />
						{busy ? 'Starting…' : `Connect with ${provider.name}`}
					</Button>
					<button
						type="button"
						class="w-fit text-xs text-muted-foreground hover:underline"
						onclick={() => (step = 'provider')}
					>
						Back
					</button>
				{:else}
					{#each provider.authFields as field (field.name)}
						<label class="flex flex-col gap-1">
							<span class="text-xs font-medium text-muted-foreground">{field.label}</span>
							<input
								type={field.type === 'password' ? 'password' : 'text'}
								bind:value={formValues[field.name]}
								class="rounded-md border border-input bg-secondary px-2 py-1.5 text-sm outline-none focus:border-primary/60"
							/>
							{#if field.help}
								<span class="text-[11px] text-muted-foreground">{field.help}</span>
							{/if}
						</label>
					{/each}
					<div class="flex justify-end gap-2">
						<Button variant="ghost" size="sm" onclick={() => (step = 'provider')}>Back</Button>
						<Button
							size="sm"
							disabled={busy}
							onclick={submitForm}
							data-testid="integration-connect-submit"
						>
							{busy ? 'Connecting…' : 'Connect'}
						</Button>
					</div>
				{/if}
			</div>
		{:else if step === 'done'}
			<div class="flex flex-col gap-3">
				{#if apiKey}
					<p class="text-sm">Your API key — copy it now, it won't be shown again:</p>
					<div class="flex items-center gap-2 rounded-md border border-input bg-secondary p-2">
						<code class="min-w-0 flex-1 truncate font-mono text-xs" data-testid="integration-api-key">
							{apiKey}
						</code>
						<Button variant="outline" size="sm" onclick={copyKey}>
							<Copy class="size-3.5" />
							{copied ? 'Copied' : 'Copy'}
						</Button>
					</div>
				{:else}
					<p class="text-sm">
						Integration connected. You can configure it from the integration's settings.
					</p>
				{/if}
				<div class="flex justify-end">
					<Button size="sm" onclick={() => (open = false)}>Done</Button>
				</div>
			</div>
		{/if}
	</Dialog.Content>
</Dialog.Root>
