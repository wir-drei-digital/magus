<script lang="ts">
	import { Check, Plus, Trash2 } from '@lucide/svelte';
	import {
		updateIntegrationConfig,
		type AgentIntegration,
		type IntegrationConfig
	} from '$lib/ash/api';
	import { Button } from '$lib/components/ui/button';

	let {
		integration,
		onSaved
	}: {
		integration: AgentIntegration;
		onSaved?: () => void;
	} = $props();

	// Local editable copies, re-seeded whenever the integration's config changes.
	let feeds = $state<string[]>([]);
	let pollInterval = $state(60);
	let errorThreshold = $state(5);
	let windowMinutes = $state(5);
	let busy = $state(false);
	let saved = $state(false);
	let error = $state<string | null>(null);

	$effect(() => {
		const c = integration.config ?? {};
		feeds = Array.isArray(c.feed_urls) ? (c.feed_urls as string[]).slice() : [];
		pollInterval = typeof c.poll_interval_minutes === 'number' ? c.poll_interval_minutes : 60;
		errorThreshold = typeof c.error_threshold === 'number' ? c.error_threshold : 5;
		windowMinutes = typeof c.window_minutes === 'number' ? c.window_minutes : 5;
	});

	const webhookSecret = $derived(
		typeof integration.config?.webhook_secret === 'string' ? integration.config.webhook_secret : null
	);
	const keyPrefix = $derived(
		typeof integration.config?.key_prefix === 'string' ? integration.config.key_prefix : null
	);

	// Replace-style update (mirrors the classic): merge the patch over the
	// existing config so we never drop sibling keys (webhook_secret, etc.).
	async function save(patch: Partial<IntegrationConfig>) {
		busy = true;
		error = null;
		saved = false;
		const result = await updateIntegrationConfig(integration.id, { ...integration.config, ...patch });
		busy = false;
		if (result.success) {
			saved = true;
			onSaved?.();
		} else {
			error = result.errors[0]?.message ?? 'Could not save.';
		}
	}

	function saveFeeds() {
		void save({
			feed_urls: feeds.map((f) => f.trim()).filter((f) => f !== ''),
			poll_interval_minutes: pollInterval
		});
	}

	function saveLog() {
		void save({ error_threshold: errorThreshold, window_minutes: windowMinutes });
	}
</script>

{#if integration.providerKey === 'rss_source'}
	<div class="mt-2 flex flex-col gap-2 border-t border-input pt-2" data-testid="rss-config">
		<span class="text-[10px] tracking-wider text-muted-foreground uppercase">Feeds</span>
		{#each feeds as _, i (i)}
			<div class="flex items-center gap-2">
				<input
					type="url"
					placeholder="https://example.com/feed.xml"
					bind:value={feeds[i]}
					class="min-w-0 flex-1 rounded-md border border-input bg-secondary px-2 py-1 text-xs outline-none focus:border-primary/60"
				/>
				<button
					type="button"
					class="rounded-md p-1 text-muted-foreground hover:text-destructive"
					aria-label="Remove feed"
					onclick={() => (feeds = feeds.filter((_, j) => j !== i))}
				>
					<Trash2 class="size-3.5" />
				</button>
			</div>
		{/each}
		<Button variant="ghost" size="sm" class="w-fit" onclick={() => (feeds = [...feeds, ''])}>
			<Plus class="size-3.5" /> Add feed
		</Button>
		<label class="flex items-center gap-2 text-xs text-muted-foreground">
			Poll every
			<input
				type="number"
				min="5"
				bind:value={pollInterval}
				class="w-16 rounded-md border border-input bg-secondary px-2 py-1 text-xs outline-none focus:border-primary/60"
			/>
			minutes
		</label>
		<div class="flex items-center gap-2">
			<Button size="sm" disabled={busy} onclick={saveFeeds} data-testid="rss-save">
				{busy ? 'Saving…' : 'Save feeds'}
			</Button>
			{#if saved}<span class="flex items-center gap-1 text-xs text-success"><Check class="size-3" /> Saved</span>{/if}
		</div>
	</div>
{:else if integration.providerKey === 'log_source'}
	<div class="mt-2 flex flex-col gap-2 border-t border-input pt-2" data-testid="log-config">
		{#if webhookSecret}
			<div class="flex flex-col gap-1">
				<span class="text-[10px] tracking-wider text-muted-foreground uppercase">Webhook secret</span>
				<code class="truncate rounded-md border border-input bg-secondary px-2 py-1 font-mono text-xs">
					{webhookSecret}
				</code>
				<span class="text-[11px] text-muted-foreground">Send as the <code>X-API-Key</code> header.</span>
			</div>
		{/if}
		<div class="flex items-center gap-2 text-xs text-muted-foreground">
			Alert after
			<input
				type="number"
				min="1"
				bind:value={errorThreshold}
				class="w-14 rounded-md border border-input bg-secondary px-2 py-1 text-xs outline-none focus:border-primary/60"
			/>
			errors in
			<input
				type="number"
				min="1"
				bind:value={windowMinutes}
				class="w-14 rounded-md border border-input bg-secondary px-2 py-1 text-xs outline-none focus:border-primary/60"
			/>
			minutes
		</div>
		<div class="flex items-center gap-2">
			<Button size="sm" disabled={busy} onclick={saveLog} data-testid="log-save">
				{busy ? 'Saving…' : 'Save thresholds'}
			</Button>
			{#if saved}<span class="flex items-center gap-1 text-xs text-success"><Check class="size-3" /> Saved</span>{/if}
		</div>
	</div>
{:else if integration.providerKey === 'api' && keyPrefix}
	<div class="mt-2 border-t border-input pt-2" data-testid="api-config">
		<span class="text-xs text-muted-foreground">
			Key: <code class="font-mono">{keyPrefix}…</code> (full key shown only at creation)
		</span>
	</div>
{/if}

{#if error}<p class="mt-1 text-xs text-destructive">{error}</p>{/if}
