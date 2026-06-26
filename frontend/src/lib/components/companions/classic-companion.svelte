<script lang="ts">
	import { PanelRight } from '@lucide/svelte';
	import type { CompanionSpec } from '$lib/ash/api';
	import CompanionFrame from './companion-frame.svelte';

	let { spec, onClose }: { spec: CompanionSpec; onClose: () => void } = $props();

	const LABELS: Record<string, string> = {
		service: 'Service pane',
		spreadsheet: 'Spreadsheet',
		conversation: 'Chat companion'
	};

	const label = $derived(LABELS[spec.type] ?? spec.type);
</script>

<CompanionFrame title={label} {onClose}>
	{#snippet icon()}
		<PanelRight class="size-4 shrink-0 text-muted-foreground" />
	{/snippet}

	<div class="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
		<p class="text-sm text-muted-foreground">
			The {label.toLowerCase()} hasn't moved to the new workbench yet.
		</p>
		<a
			href="/chat"
			data-sveltekit-reload
			class="text-sm font-medium text-primary underline-offset-2 hover:underline"
		>
			Open in classic UI
		</a>
	</div>
</CompanionFrame>
