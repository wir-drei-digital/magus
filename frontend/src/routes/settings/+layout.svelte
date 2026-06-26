<script lang="ts">
	import type { Snippet } from 'svelte';
	import { Settings } from '@lucide/svelte';
	import { page } from '$app/state';

	let { children }: { children: Snippet } = $props();

	// Name the active section in the content header (the nav highlights it too,
	// but a deep-linked user needs the label where they're looking).
	const SECTION_LABELS: Record<string, string> = {
		profile: 'Profile',
		preferences: 'Preferences',
		subscription: 'Subscription',
		integrations: 'Integrations',
		knowledge: 'Knowledge',
		storage: 'Storage',
		'api-tokens': 'API tokens',
		data: 'Data'
	};
	const sectionLabel = $derived(
		SECTION_LABELS[page.url.pathname.split('/').filter(Boolean).pop() ?? ''] ?? null
	);
</script>

<svelte:head>
	<title>Magus — {sectionLabel ? `${sectionLabel} · Settings` : 'Settings'}</title>
</svelte:head>

<!-- Section navigation lives in the main nav pane (SettingsNav); this view is
     just the header + the active section's content. -->
<div class="flex h-full min-h-0 flex-col" data-testid="settings-view">
	<header
		class="flex shrink-0 items-center gap-2 border-b bg-background/80 py-3 pr-6 pl-14 md:pl-6"
	>
		<Settings class="size-4 shrink-0 text-muted-foreground" />
		<h1 class="min-w-0 flex-1 truncate text-base font-semibold">
			{#if sectionLabel}
				<span class="font-normal text-muted-foreground">Settings</span>
				<span class="text-muted-foreground" aria-hidden="true">/</span>
				{sectionLabel}
			{:else}
				Settings
			{/if}
		</h1>
	</header>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto">
		<div class="mx-auto w-full max-w-2xl p-6">
			{@render children()}
		</div>
	</div>
</div>
