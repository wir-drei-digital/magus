<script lang="ts" module>
	import type { TaskPriority } from '$lib/ash/api';
	import { ChevronsUp, ArrowUp, Equal, ArrowDown } from '@lucide/svelte';

	/**
	 * Per-priority presentation: a directional glyph + a tokenized tint. Urgent
	 * reads as destructive (red), High as warning (amber), Normal as info (blue),
	 * Low as muted/grey: the calm work-tool ladder from the design.
	 */
	const PRIORITY = {
		urgent: { label: 'Urgent', icon: ChevronsUp, classes: 'bg-destructive/10 text-destructive' },
		high: { label: 'High', icon: ArrowUp, classes: 'bg-warning/10 text-warning' },
		normal: { label: 'Normal', icon: Equal, classes: 'bg-info/10 text-info' },
		low: { label: 'Low', icon: ArrowDown, classes: 'bg-muted text-muted-foreground' }
	} as const satisfies Record<TaskPriority, { label: string; icon: unknown; classes: string }>;
</script>

<script lang="ts">
	let { priority, class: className = '' }: { priority: TaskPriority; class?: string } = $props();

	const spec = $derived(PRIORITY[priority]);
</script>

<span
	data-testid="priority-badge"
	data-priority={priority}
	class="inline-flex items-center gap-0.5 rounded px-1 py-0.5 text-[10px] font-semibold tracking-wide uppercase {spec.classes} {className}"
>
	<spec.icon class="size-3 shrink-0" />
	{spec.label}
</span>
