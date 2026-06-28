<script lang="ts" module>
	import type { Lifecycle } from '$lib/ash/api';
	import { CircleDashed, CircleDot, CircleCheck, PackageCheck } from '@lucide/svelte';

	/**
	 * Per-lifecycle presentation: an icon + a tokenized tint that reads the same in
	 * light and dark. The ladder is deliberate:
	 *   - delivered : success (green), closed out, the goal state.
	 *   - done      : warning (amber), complete but NOT yet delivered; the nudge.
	 *   - active    : primary, work in flight.
	 *   - draft     : muted-foreground, nothing started.
	 * Tokens only (no raw hex), and state lives in this pill, never a side-stripe.
	 */
	const LIFECYCLE = {
		draft: { label: 'Draft', icon: CircleDashed, classes: 'bg-muted text-muted-foreground' },
		active: { label: 'Active', icon: CircleDot, classes: 'bg-primary/10 text-primary' },
		done: { label: 'Done', icon: CircleCheck, classes: 'bg-warning/10 text-warning' },
		delivered: { label: 'Delivered', icon: PackageCheck, classes: 'bg-success/10 text-success' }
	} as const satisfies Record<Lifecycle, { label: string; icon: unknown; classes: string }>;
</script>

<script lang="ts">
	let { lifecycle, class: className = '' }: { lifecycle: Lifecycle; class?: string } = $props();

	const spec = $derived(LIFECYCLE[lifecycle]);
</script>

<span
	data-testid="lifecycle-badge"
	data-lifecycle={lifecycle}
	class="inline-flex items-center gap-1 rounded-full px-1.5 py-0.5 text-[10px] font-semibold tracking-wide uppercase {spec.classes} {className}"
>
	<spec.icon class="size-2.5 shrink-0" />
	{spec.label}
</span>
