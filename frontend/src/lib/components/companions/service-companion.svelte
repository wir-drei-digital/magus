<script lang="ts">
	import { ExternalLink, Globe, RefreshCw } from '@lucide/svelte';
	import type { CompanionSpec } from '$lib/ash/api';
	import CompanionFrame from './companion-frame.svelte';

	let { spec, onClose }: { spec: CompanionSpec; onClose: () => void } = $props();

	// start_service opens the companion with id = conversationId. The preview is
	// served by the authenticated /sandbox/preview/<id>/ reverse proxy, which
	// re-authorizes every request (same pattern as the file serve route), so the
	// iframe can point at it directly. A stopped/suspended sandbox renders the
	// proxy's own error page. Region-screenshot → chat is still tracked
	// separately (the PDF viewer's selection flow now exists to mirror, but an
	// iframe needs html-to-image capture instead of a canvas crop).
	const url = $derived(`/sandbox/preview/${spec.id}/`);
	let reloadKey = $state(0);
</script>

<CompanionFrame title={spec.name ?? 'Service'} {onClose}>
	{#snippet icon()}
		<Globe class="size-4 shrink-0 text-muted-foreground" />
	{/snippet}

	<div class="flex shrink-0 items-center gap-1 border-b px-2 py-1.5">
		<button
			type="button"
			onclick={() => (reloadKey += 1)}
			class="wb-pill-btn gap-1 text-xs"
			title="Reload service"
			aria-label="Reload service"
			data-testid="service-reload"
		>
			<RefreshCw class="size-3.5" />
			Reload
		</button>
		<a
			href={url}
			target="_blank"
			rel="noopener noreferrer"
			class="wb-pill-btn gap-1 text-xs"
			title="Open in new tab"
			aria-label="Open in new tab"
		>
			<ExternalLink class="size-3.5" />
			Open
		</a>
	</div>

	{#key reloadKey}
		<iframe src={url} title={spec.name ?? 'Service'} class="min-h-0 w-full flex-1 border-0"
		></iframe>
	{/key}
</CompanionFrame>
