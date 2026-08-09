<script lang="ts">
	import { base } from '$app/paths';
	import { ExternalLink } from '@lucide/svelte';
	import type { ActionCardsView } from '$lib/chat/action-cards';

	// Presentational only: every decision (validation, letter labels, URL
	// safety) already happened in $lib/chat/action-cards, which is unit-tested.
	let {
		view,
		onSend,
		onPrefill
	}: {
		view: ActionCardsView;
		onSend: (text: string) => void;
		onPrefill: (text: string) => void;
	} = $props();

	const CARD_CLASS =
		'flex items-start gap-3 rounded-xl border bg-secondary/40 p-3 text-left transition-colors hover:border-primary/60 hover:bg-accent/50';
</script>

{#if view}
	<div
		class={view.layout === 'grid' ? 'mt-3 grid gap-2 sm:grid-cols-2' : 'mt-3 flex flex-col gap-2'}
		data-testid="action-cards"
		data-layout={view.layout}
	>
		{#each view.cards as card (card.label)}
			{#snippet body()}
				<span
					class="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-md bg-primary/10 font-mono text-[11px] font-medium text-primary"
					>{card.label}</span
				>
				<span class="min-w-0">
					<span class="block text-sm font-medium">{card.title}</span>
					{#if card.description}
						<span class="block text-xs text-muted-foreground">{card.description}</span>
					{/if}
					{#if card.kind === 'link_external'}
						<span class="mt-0.5 flex items-center gap-1 text-xs text-muted-foreground">
							<ExternalLink class="size-3" />{card.host}
						</span>
					{/if}
				</span>
			{/snippet}

			{#if card.kind === 'send'}
				<button
					type="button"
					class={CARD_CLASS}
					data-testid="action-card"
					onclick={() => onSend(card.payload)}
				>
					{@render body()}
				</button>
			{:else if card.kind === 'prefill'}
				<button
					type="button"
					class={CARD_CLASS}
					data-testid="action-card"
					onclick={() => onPrefill(card.payload)}
				>
					{@render body()}
				</button>
			{:else if card.kind === 'link_internal'}
				<a href="{base}{card.path}" class={CARD_CLASS} data-testid="action-card">
					{@render body()}
				</a>
			{:else if card.kind === 'link_external'}
				<a
					href={card.url}
					target="_blank"
					rel="noopener noreferrer"
					class={CARD_CLASS}
					data-testid="action-card"
				>
					{@render body()}
				</a>
			{:else}
				<!-- Refused navigate target: shown, never clickable. -->
				<span class="{CARD_CLASS} opacity-60" data-testid="action-card">
					{@render body()}
				</span>
			{/if}
		{/each}
	</div>
{/if}
