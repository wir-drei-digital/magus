<script lang="ts">
	import { NotebookPen } from '@lucide/svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { EmptyState } from '$lib/components/ui/empty-state';
	import MobileNavButton from '$lib/components/shell/mobile-nav-button.svelte';

	// One-shot: deep links sync the nav once; afterwards the mode strip
	// may switch the nav freely without this route forcing it back.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'brain') void workbench.setMode('brain');
	});
</script>

<svelte:head>
	<title>Magus — Brain</title>
</svelte:head>

<div class="relative h-full">
	<!-- No pane header on the empty state — the nav button floats in its corner. -->
	<MobileNavButton class="absolute top-2.5 left-3" />
	<EmptyState title="No page open" description="Pick a page from the left, or create a new one.">
		{#snippet icon()}<NotebookPen />{/snippet}
	</EmptyState>
</div>
