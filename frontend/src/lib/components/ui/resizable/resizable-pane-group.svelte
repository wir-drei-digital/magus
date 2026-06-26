<script lang="ts">
	import { PaneGroup, type PaneGroupProps } from 'paneforge';
	import { cn } from '$lib/utils.js';

	let {
		ref = $bindable(null),
		class: className,
		...restProps
	}: PaneGroupProps & { ref?: HTMLElement | null } = $props();
</script>

<PaneGroup
	bind:ref
	data-slot="resizable-pane-group"
	class={cn('flex h-full w-full data-[direction=vertical]:flex-col', className)}
	{...restProps}
/>
