<script lang="ts">
	import { Bot } from '@lucide/svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { EmptyState } from '$lib/components/ui/empty-state';

	// One-shot: deep links sync the nav once; afterwards the mode strip
	// may switch the nav freely without this route forcing it back.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'agents') void workbench.setMode('agents');
	});
</script>

<svelte:head>
	<title>Magus — Agents</title>
</svelte:head>

<EmptyState title="No agent selected" description="Pick an agent from the left, or create a new one.">
	{#snippet icon()}<Bot />{/snippet}
</EmptyState>
