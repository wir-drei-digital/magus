<script lang="ts">
	import type { Snippet } from 'svelte';
	import { page } from '$app/state';
	import { workbench } from '$lib/stores/workbench.svelte';
	import PromptGallery from './components/prompt-gallery.svelte';

	let { children }: { children: Snippet } = $props();

	// The gallery lives here (not in +page) so it stays mounted across
	// /prompts <-> /prompts/[id]: selecting a card narrows it into a master rail
	// and the reader (the [promptId] page) opens beside it. Scroll position and
	// filters survive, and deep links + the back button work.
	const selectedId = $derived(page.params.promptId ?? null);
	const readerOpen = $derived(selectedId !== null);

	// Deep links into a prompt put the workbench in prompts mode once; afterwards
	// the mode strip can switch freely.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'prompts') void workbench.setMode('prompts');
	});
</script>

<svelte:head>
	<title>Magus — Prompts</title>
</svelte:head>

<div class="flex h-full min-h-0" data-testid="prompts-view">
	<!-- Full width at rest; a master rail when a reader is open. On narrow
	     screens the reader takes the whole pane, so the gallery hides. -->
	<div
		class="flex min-h-0 min-w-0 flex-col {readerOpen
			? 'hidden md:flex md:w-[44%] md:shrink-0 lg:w-[40%]'
			: 'flex-1'}"
	>
		<PromptGallery {selectedId} compact={readerOpen} />
	</div>

	{#if readerOpen}
		<div class="min-h-0 min-w-0 flex-1 md:border-l">
			{@render children()}
		</div>
	{/if}
</div>
