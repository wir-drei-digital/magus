<script lang="ts">
	import { onMount } from 'svelte';
	import { Star, EyeOff, Eye, ArrowUp, ArrowDown } from '@lucide/svelte';
	import { Section as SettingsSection } from '$lib/components/crud';
	import { listActiveModels, type ModelPreference, type ModelSummary } from '$lib/ash/api';
	import { cachedModelPreferences } from '$lib/chat/catalog';
	import { prefsById } from '$lib/chat/model-grouping';
	import { toggleFavorite, toggleHidden, moveModel } from '$lib/chat/model-preferences';

	let models = $state<ModelSummary[]>([]);
	let prefs = $state<ModelPreference[]>([]);
	let loading = $state(true);
	let busy = $state(false);

	const prefMap = $derived(prefsById(prefs));

	// Favorites in display order: by stored position (nulls last), then name.
	const favorites = $derived(
		models
			.filter((m) => prefMap.get(m.id)?.favorite)
			.sort(
				(a, b) =>
					(prefMap.get(a.id)?.position ?? Number.POSITIVE_INFINITY) -
						(prefMap.get(b.id)?.position ?? Number.POSITIVE_INFINITY) ||
					a.name.localeCompare(b.name)
			)
	);

	onMount(() => void load());

	async function load() {
		const [m, p] = await Promise.all([listActiveModels(), cachedModelPreferences()]);
		if (m.success) models = m.data;
		if (p.success) prefs = p.data;
		loading = false;
	}

	async function refreshPrefs() {
		const p = await cachedModelPreferences();
		if (p.success) prefs = p.data;
	}

	async function onFavorite(modelId: string, next: boolean) {
		if (busy) return;
		busy = true;
		await toggleFavorite(modelId, next);
		await refreshPrefs();
		busy = false;
	}

	async function onHide(modelId: string, next: boolean) {
		if (busy) return;
		busy = true;
		await toggleHidden(modelId, next);
		await refreshPrefs();
		busy = false;
	}

	// Move within the favorites list by splice-removing the item and reinserting it
	// at the target index, then renumber the whole favorites list 0..n-1 so order
	// is stable.
	async function move(index: number, delta: number) {
		if (busy) return;
		const next = index + delta;
		if (next < 0 || next >= favorites.length) return;
		busy = true;
		const reordered = [...favorites];
		const [item] = reordered.splice(index, 1);
		reordered.splice(next, 0, item);
		for (let i = 0; i < reordered.length; i++) {
			await moveModel(reordered[i].id, i);
		}
		await refreshPrefs();
		busy = false;
	}
</script>

{#if loading}
	<div class="space-y-2" data-testid="settings-models-loading">
		{#each [1, 2, 3, 4] as i (i)}
			<div class="h-10 animate-pulse rounded-lg bg-muted/60"></div>
		{/each}
	</div>
{:else}
	<div class="space-y-6" data-testid="settings-models">
		{#if favorites.length > 0}
			<SettingsSection title="Favorites" description="Pinned to the top of the model picker.">
				<ul class="divide-y" data-testid="settings-models-favorites">
					{#each favorites as model, index (model.id)}
						<li class="flex items-center gap-2 py-2 first:pt-0">
							<span class="flex-1 truncate text-sm">{model.name}</span>
							<button
								type="button"
								disabled={busy || index === 0}
								onclick={() => move(index, -1)}
								data-testid="model-move-up"
								aria-label="Move up"
								class="rounded p-1 hover:bg-accent/60 disabled:opacity-40"
							>
								<ArrowUp class="size-4" />
							</button>
							<button
								type="button"
								disabled={busy || index === favorites.length - 1}
								onclick={() => move(index, 1)}
								data-testid="model-move-down"
								aria-label="Move down"
								class="rounded p-1 hover:bg-accent/60 disabled:opacity-40"
							>
								<ArrowDown class="size-4" />
							</button>
						</li>
					{/each}
				</ul>
			</SettingsSection>
		{/if}

		<SettingsSection
			title="All models"
			description="Star to favorite, hide to remove from the picker."
		>
			<ul class="divide-y" data-testid="settings-models-list">
				{#each models as model (model.id)}
					{@const pref = prefMap.get(model.id)}
					<li class="flex items-center gap-2 py-2 first:pt-0">
						<button
							type="button"
							disabled={busy}
							onclick={() => onFavorite(model.id, !(pref?.favorite ?? false))}
							data-testid="model-favorite-toggle"
							aria-label={pref?.favorite ? 'Unfavorite' : 'Favorite'}
							aria-pressed={pref?.favorite ?? false}
							class="rounded p-1 hover:bg-accent/60"
						>
							<Star
								class="size-4 {pref?.favorite
									? 'fill-primary text-primary'
									: 'text-muted-foreground'}"
							/>
						</button>
						<span
							class="flex-1 truncate text-sm {pref?.hidden
								? 'text-muted-foreground line-through'
								: ''}"
						>
							{model.name}
						</span>
						{#if model.provider}
							<span class="shrink-0 font-mono text-[10px] text-muted-foreground uppercase">
								{model.provider}
							</span>
						{/if}
						<button
							type="button"
							disabled={busy}
							onclick={() => onHide(model.id, !(pref?.hidden ?? false))}
							data-testid="model-hide-toggle"
							aria-label={pref?.hidden ? 'Unhide' : 'Hide'}
							aria-pressed={pref?.hidden ?? false}
							class="rounded p-1 hover:bg-accent/60"
						>
							{#if pref?.hidden}
								<EyeOff class="size-4 text-muted-foreground" />
							{:else}
								<Eye class="size-4 text-muted-foreground" />
							{/if}
						</button>
					</li>
				{/each}
			</ul>
		</SettingsSection>
	</div>
{/if}
