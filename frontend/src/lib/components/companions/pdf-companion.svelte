<script lang="ts">
	import { File, ZoomIn, ZoomOut } from '@lucide/svelte';
	import type { CompanionSpec } from '$lib/ash/api';
	import PdfViewer from '$lib/components/files/pdf-viewer.svelte';
	import CompanionFrame from './companion-frame.svelte';

	let {
		spec,
		onClose,
		onAskSelection
	}: {
		spec: CompanionSpec;
		onClose: () => void;
		/** Region capture → composer context pill (classic pdf:ask_about_selection). */
		onAskSelection?: (selection: {
			image: string;
			text: string;
			page: number | null;
			filename: string | null;
		}) => void;
	} = $props();

	// The classic workbench stores a pre-resolved preview URL in the spec.
	const url = $derived(typeof spec.url === 'string' ? spec.url : null);

	// Classic PdfPaneComponent zoom steps; 100 = 1 PDF point per CSS pixel.
	const ZOOM_STEPS = [25, 50, 75, 100, 125, 150, 200, 300];
	let zoom = $state(100);

	function zoomBy(direction: 1 | -1) {
		const index = ZOOM_STEPS.indexOf(zoom);
		const next = ZOOM_STEPS[index + direction];
		if (next) zoom = next;
	}
</script>

<CompanionFrame title={spec.name ?? 'PDF'} {onClose}>
	{#snippet icon()}
		<File class="size-4 shrink-0 text-muted-foreground" />
	{/snippet}

	{#snippet headerActions()}
		{#if url}
			<div class="flex items-center gap-0.5">
				<button
					type="button"
					class="wb-pill-btn wb-pill-btn-square"
					aria-label="Zoom out"
					title="Zoom out"
					disabled={zoom === ZOOM_STEPS[0]}
					data-testid="pdf-zoom-out"
					onclick={() => zoomBy(-1)}
				>
					<ZoomOut class="size-3.5" />
				</button>
				<button
					type="button"
					class="min-w-11 rounded-md px-1 py-0.5 text-center text-xs tabular-nums text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
					title="Reset zoom"
					data-testid="pdf-zoom-reset"
					onclick={() => (zoom = 100)}
				>
					{zoom}%
				</button>
				<button
					type="button"
					class="wb-pill-btn wb-pill-btn-square"
					aria-label="Zoom in"
					title="Zoom in"
					disabled={zoom === ZOOM_STEPS[ZOOM_STEPS.length - 1]}
					data-testid="pdf-zoom-in"
					onclick={() => zoomBy(1)}
				>
					<ZoomIn class="size-3.5" />
				</button>
			</div>
		{/if}
	{/snippet}

	{#if url}
		<PdfViewer
			{url}
			scale={zoom / 100}
			onSelection={onAskSelection
				? (selection) => onAskSelection({ ...selection, filename: spec.name ?? null })
				: undefined}
		/>
	{:else}
		<p class="p-4 text-sm text-muted-foreground">
			This PDF has no preview URL — re-open it from the file browser.
		</p>
	{/if}
</CompanionFrame>
