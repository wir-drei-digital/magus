<script lang="ts">
	import { onMount } from 'svelte';
	import { Trash2 } from '@lucide/svelte';
	import {
		disconnectKnowledgeSource,
		knowledgeSources,
		type KnowledgeSourceEntry
	} from '$lib/ash/api';
	import SettingsSection from '$lib/components/crud/section.svelte';
	import { confirmAction } from '$lib/stores/confirm.svelte';
	import { providerLabel } from '$lib/integrations/provider-label';

	let sources = $state<KnowledgeSourceEntry[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let busyId = $state<string | null>(null);

	onMount(() => void load());

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

			<p class="mt-4 text-xs text-muted-foreground">
				Connecting a new source (Notion, Google Drive, and others) runs an authorization wizard that
				is not yet available in the new UI.
			</p>
		</SettingsSection>
	</div>
{/if}
