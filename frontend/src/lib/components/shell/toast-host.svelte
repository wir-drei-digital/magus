<script lang="ts">
	import { X } from '@lucide/svelte';
	import { toastStore } from '$lib/stores/toast.svelte';
</script>

{#if toastStore.toasts.length > 0}
	<div
		class="pointer-events-none fixed inset-x-0 bottom-0 z-50 flex flex-col items-center gap-2 p-4 pb-[max(1rem,env(safe-area-inset-bottom))]"
		data-testid="toast-host"
	>
		{#each toastStore.toasts as entry (entry.id)}
			<div
				class="pointer-events-auto flex w-full max-w-sm items-center gap-3 rounded-lg border bg-popover px-4 py-3 text-sm text-popover-foreground shadow-lg"
				role="status"
			>
				<span class="min-w-0 flex-1">{entry.message}</span>
				{#if entry.action}
					<button
						type="button"
						class="shrink-0 font-medium text-primary-link hover:underline"
						onclick={() => toastStore.runAction(entry.id)}
					>
						{entry.action.label}
					</button>
				{/if}
				<button
					type="button"
					class="shrink-0 text-muted-foreground transition-colors hover:text-foreground"
					aria-label="Dismiss"
					onclick={() => toastStore.dismiss(entry.id)}
				>
					<X class="size-3.5" />
				</button>
			</div>
		{/each}
	</div>
{/if}
