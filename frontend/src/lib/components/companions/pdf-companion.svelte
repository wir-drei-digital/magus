<script lang="ts">
	import { File } from '@lucide/svelte';
	import type { CompanionSpec } from '$lib/ash/api';
	import CompanionFrame from './companion-frame.svelte';

	let { spec, onClose }: { spec: CompanionSpec; onClose: () => void } = $props();

	// The classic workbench stores a pre-resolved preview URL in the spec;
	// the browser's native PDF viewer renders it. The pdfjs wrapper with
	// text-selection-to-composer is tracked separately.
	const url = $derived(typeof spec.url === 'string' ? spec.url : null);
</script>

<CompanionFrame title={spec.name ?? 'PDF'} {onClose}>
	{#snippet icon()}
		<File class="size-4 shrink-0 text-muted-foreground" />
	{/snippet}

	{#if url}
		<iframe src={url} title={spec.name ?? 'PDF'} class="min-h-0 w-full flex-1 border-0"></iframe>
	{:else}
		<p class="p-4 text-sm text-muted-foreground">
			This PDF has no preview URL — re-open it from the file browser.
		</p>
	{/if}
</CompanionFrame>
