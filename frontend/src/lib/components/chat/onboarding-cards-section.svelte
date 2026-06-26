<script lang="ts">
	import { onMount } from 'svelte';
	import { base } from '$app/paths';
	import {
		Bell,
		Box,
		Brain,
		CornerDownRight,
		FileText,
		Globe,
		Puzzle,
		Users
	} from '@lucide/svelte';
	import { onboardingCards, type OnboardingCard } from '$lib/ash/api';

	// Classic new-chat "Try it out": discovery cards for features the user has
	// not used yet. Each links to ?skill=onboarding&topic=<key>, which the
	// landing turns into a skill-seeded conversation.
	let cards = $state<OnboardingCard[]>([]);
	let firstTime = $state(false);

	onMount(() => {
		void onboardingCards().then((result) => {
			if (result.success) {
				cards = result.data.cards;
				firstTime = result.data.firstTime;
			}
		});
	});

	const ICONS: Record<string, typeof Bell> = {
		'lucide-bell': Bell,
		'lucide-box': Box,
		'lucide-brain': Brain,
		'lucide-corner-down-right': CornerDownRight,
		'lucide-file-text': FileText,
		'lucide-globe': Globe,
		'lucide-puzzle': Puzzle,
		'lucide-users': Users
	};
</script>

{#if cards.length > 0}
	<div class="mb-6" data-testid="onboarding-cards">
		{#if !firstTime}
			<h2
				class="mb-3 font-mono text-[10px] font-medium tracking-[0.12em] text-muted-foreground uppercase"
			>
				Try it out
			</h2>
		{/if}
		<div class="grid gap-2 sm:grid-cols-2">
			{#each cards as card (card.key)}
				{@const Icon = ICONS[card.icon] ?? Puzzle}
				<a
					href="{base}/chat?skill=onboarding&topic={card.topic}"
					class="flex items-start gap-3 rounded-xl border bg-secondary/40 p-3 text-left transition-colors hover:border-primary/60 hover:bg-accent/50"
					data-testid="onboarding-card"
				>
					<Icon class="mt-0.5 size-5 shrink-0 text-primary" />
					<span class="min-w-0">
						<span class="block text-sm font-medium">{card.title}</span>
						<span class="block text-xs text-muted-foreground">{card.description}</span>
					</span>
				</a>
			{/each}
		</div>
	</div>
{/if}
