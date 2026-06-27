<script lang="ts">
	import { onMount } from 'svelte';
	import { Trash2 } from '@lucide/svelte';
	import {
		disconnectKnowledgeSource,
		finalizeKnowledgeOauth,
		knowledgeSources,
		type KnowledgeSourceEntry
	} from '$lib/ash/api';
	import SettingsSection from '$lib/components/crud/section.svelte';
	import { Button } from '$lib/components/ui/button';
	import KnowledgeConnectWizard from '$lib/components/knowledge/knowledge-connect-wizard.svelte';
	import { confirmAction } from '$lib/stores/confirm.svelte';
	import { providerLabel } from '$lib/integrations/provider-label';

	let sources = $state<KnowledgeSourceEntry[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let busyId = $state<string | null>(null);

	let wizardOpen = $state(false);
	let resumeSource = $state<KnowledgeSourceEntry | null>(null);

	onMount(() => {
		void load();
		void maybeResumeOauth();
	});

	// After an OAuth redirect, the callback stashed the tokens in the session and
	// sent us back with ?wizard_provider=<key>. Finalize server-side (creating the
	// source without the tokens touching the browser), then resume the wizard at
	// the folder picker. Clear the param so a refresh does not re-finalize.
	async function maybeResumeOauth() {
		const params = new URLSearchParams(window.location.search);
		const provider = params.get('wizard_provider');
		if (!provider) return;

		const url = new URL(window.location.href);
		url.searchParams.delete('wizard_provider');
		window.history.replaceState({}, '', url);

		const result = await finalizeKnowledgeOauth(provider);
		if (result.ok) {
			await load();
			resumeSource = result.source;
			wizardOpen = true;
		} else {
			error = result.error;
		}
	}

	function openWizard() {
		resumeSource = null;
		wizardOpen = true;
	}

	async function load() {
		const result = await knowledgeSources();
		if (result.success) sources = result.data;
		else error = result.errors[0]?.message ?? 'Could not load knowledge sources';
		loading = false;
	}

	async function disconnect(source: KnowledgeSourceEntry) {
		const ok = await confirmAction({
			title: `Disconnect ${source.name}?`,
			description: 'Its synced content will stop updating.',
			confirmLabel: 'Disconnect'
		});
		if (!ok) return;
		busyId = source.id;
		error = null;
		const result = await disconnectKnowledgeSource(source.id);
		busyId = null;
		if (result.success) sources = sources.filter((entry) => entry.id !== source.id);
		else error = result.errors[0]?.message ?? 'Could not disconnect source';
	}


	function statusClass(status: string): string {
		if (status === 'active') return 'bg-success/15 text-success';
		if (status === 'error') return 'bg-destructive/15 text-destructive';
		return 'bg-secondary text-muted-foreground';
	}
</script>

{#if loading}
	<div class="space-y-4" data-testid="settings-knowledge-loading">
		{#each [1, 2] as i (i)}
			<div class="h-20 animate-pulse rounded-xl bg-muted/60"></div>
		{/each}
	</div>
{:else}
	<div class="space-y-6" data-testid="settings-knowledge">
		<SettingsSection
			title="Knowledge sources"
			description="External providers ingested into your knowledge base."
		>
			{#if error}
				<p class="mb-2 text-xs text-destructive">{error}</p>
			{/if}

			{#if sources.length === 0}
				<p class="text-sm text-muted-foreground">No connected sources.</p>
			{:else}
				<ul class="flex flex-col gap-1.5" data-testid="knowledge-source-list">
					{#each sources as source (source.id)}
						<li
							class="flex items-center gap-3 rounded-lg border p-3"
							data-testid="knowledge-source"
						>
							<div class="min-w-0 flex-1">
								<p class="truncate text-sm font-medium">{source.name}</p>
								<p class="truncate text-xs text-muted-foreground">
									{providerLabel(source.provider)}
								</p>
							</div>
							<span
								class="shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium {statusClass(
									source.status
								)}"
							>
								{source.status}
							</span>
							<button
								type="button"
								class="inline-flex size-7 shrink-0 items-center justify-center rounded-md text-destructive transition-colors hover:bg-destructive/10 disabled:opacity-50"
								title="Disconnect"
								disabled={busyId === source.id}
								onclick={() => void disconnect(source)}
								data-testid="knowledge-source-disconnect"
							>
								<Trash2 class="size-4" />
							</button>
						</li>
					{/each}
				</ul>
			{/if}

			<div class="mt-4">
				<Button
					size="sm"
					variant="outline"
					onclick={openWizard}
					data-testid="knowledge-connect-open"
				>
					+ Connect a source
				</Button>
			</div>
		</SettingsSection>
	</div>
{/if}

<KnowledgeConnectWizard bind:open={wizardOpen} {resumeSource} onConnected={load} />
