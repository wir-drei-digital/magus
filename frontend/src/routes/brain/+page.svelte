<script lang="ts">
	import { NotebookPen } from '@lucide/svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { EmptyState } from '$lib/components/ui/empty-state';

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

<EmptyState title="No page open" description="Pick a page from the left, or create a new one.">
	{#snippet icon()}<NotebookPen />{/snippet}
</EmptyState>
