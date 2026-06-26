<script lang="ts">
	import { onMount } from 'svelte';
	import { base } from '$app/paths';
	import { Sparkles, X } from '@lucide/svelte';
	import { dismissAnnouncement, unseenAnnouncements, type AnnouncementCard } from '$lib/ash/api';

	// Classic new-chat announcements: active cards the user hasn't dismissed.
	// Dismissal persists a "seen" usage event (net-new vs the classic no-op).
	let announcements = $state<AnnouncementCard[]>([]);

	onMount(() => {
		void unseenAnnouncements().then((result) => {
			if (result.success) announcements = result.data;
		});
	});

	async function dismiss(card: AnnouncementCard) {
		// Optimistic: drop it immediately, then persist the seen event.
		announcements = announcements.filter((entry) => entry.key !== card.key);
		void dismissAnnouncement(card.key);
	}

	// Admin-authored payloads may be in-app paths or absolute URLs.
	function learnMoreHref(payload: string): string {
		return payload.startsWith('http') ? payload : `${base}${payload}`;
	}
</script>

{#if announcements.length > 0}
	<div class="mb-4 flex flex-col gap-2" data-testid="announcements">
		{#each announcements as card (card.key)}
			<div
				class="flex items-start justify-between gap-3 rounded-xl border bg-secondary/40 p-4"
				data-testid="announcement"
			>
				<div class="flex min-w-0 items-start gap-3">
					{#if card.icon.startsWith('lucide-')}
						<Sparkles class="mt-0.5 size-5 shrink-0 text-primary" />
					{:else if card.icon}
						<span class="text-xl leading-none" aria-hidden="true">{card.icon}</span>
					{/if}
					<div class="min-w-0">
						<div class="flex items-center gap-2">
							<span
								class="rounded bg-primary/15 px-1.5 py-0.5 text-[10px] font-semibold tracking-wide text-primary uppercase"
							>
								New
							</span>
							<span class="truncate text-sm font-semibold">{card.title}</span>
						</div>
						{#if card.description}
							<p class="mt-1 text-xs text-muted-foreground">{card.description}</p>
						{/if}
						{#if card.actionPayload}
							<a
								href={learnMoreHref(card.actionPayload)}
								class="mt-1 inline-block text-xs text-primary hover:underline"
							>
								Learn more
							</a>
						{/if}
					</div>
				</div>
				<button
					type="button"
					class="shrink-0 rounded-md p-1 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
					title="Dismiss"
					aria-label="Dismiss"
					onclick={() => void dismiss(card)}
				>
					<X class="size-4" />
				</button>
			</div>
		{/each}
	</div>
{/if}
