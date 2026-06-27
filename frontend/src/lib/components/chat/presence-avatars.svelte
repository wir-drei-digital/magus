<script lang="ts">
	import {
		viewerInitials,
		viewerOverflow,
		visibleOthers,
		type PresenceViewer
	} from '$lib/chat/presence';

	let {
		viewers,
		selfUserId = null,
		max = 4
	}: {
		/** Full viewer list from the store (self + hidden included). */
		viewers: PresenceViewer[];
		/** Current user, excluded from the avatars. */
		selfUserId?: string | null;
		max?: number;
	} = $props();

	const others = $derived(visibleOthers(viewers, selfUserId));
	const overflow = $derived(viewerOverflow(others, max));
</script>

{#if others.length > 0}
	<div
		class="flex items-center -space-x-1.5"
		data-testid="presence-avatars"
		aria-label={`${others.length} other ${others.length === 1 ? 'viewer' : 'viewers'} here`}
	>
		{#each overflow.shown as viewer (viewer.userId)}
			<span
				class="flex size-6 items-center justify-center rounded-full border-2 border-background text-[10px] font-semibold text-white"
				style="background-color: {viewer.color}"
				title={viewer.name}
				data-testid="presence-avatar"
			>
				{viewerInitials(viewer)}
			</span>
		{/each}
		{#if overflow.extra > 0}
			<span
				class="flex size-6 items-center justify-center rounded-full border-2 border-background bg-secondary text-[10px] font-semibold text-muted-foreground"
				title={`${overflow.extra} more`}
				data-testid="presence-overflow"
			>
				+{overflow.extra}
			</span>
		{/if}
	</div>
{/if}
