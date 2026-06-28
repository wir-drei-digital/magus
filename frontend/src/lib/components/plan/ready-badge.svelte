<script lang="ts">
	import { Lock } from '@lucide/svelte';

	/**
	 * The tiny status pip beside a task title. `ready` is the green claimable
	 * affordance (a filled dot + READY); `blocked` is the amber lock tag. Both
	 * are dense, uppercase, and tokenized so they track light/dark.
	 */
	let {
		variant = 'ready',
		class: className = ''
	}: { variant?: 'ready' | 'blocked'; class?: string } = $props();
</script>

{#if variant === 'ready'}
	<span
		data-testid="ready-badge"
		class="inline-flex items-center gap-1 rounded-full bg-success/10 px-1.5 py-0.5 text-[10px] font-semibold tracking-wide text-success uppercase {className}"
	>
		<span class="size-1.5 rounded-full bg-success"></span>
		Ready
	</span>
{:else}
	<span
		data-testid="blocked-badge"
		class="inline-flex items-center gap-1 rounded-full bg-warning/10 px-1.5 py-0.5 text-[10px] font-semibold tracking-wide text-warning uppercase {className}"
	>
		<Lock class="size-2.5 shrink-0" />
		Blocked
	</span>
{/if}
