<script lang="ts">
	import type { QueuedMessage } from '$lib/chat/queued';

	let {
		messages,
		onSendNow,
		onRemove
	}: {
		messages: QueuedMessage[];
		onSendNow: () => void;
		onRemove: (id: string) => void;
	} = $props();
</script>

{#if messages.length > 0}
	<div class="mx-auto mb-2 w-full max-w-3xl space-y-1" data-queued-region>
		<p class="px-1 text-[11px] font-medium tracking-wide text-muted-foreground uppercase">Queued</p>
		{#each messages as msg (msg.id)}
			<div
				class="flex items-center gap-2 rounded-xl border border-dashed border-input bg-secondary/50 px-3 py-1.5 text-sm text-muted-foreground"
				data-queued-message
				data-queued-id={msg.id}
			>
				<span class="min-w-0 flex-1 truncate">{msg.text}</span>
				<button
					type="button"
					class="shrink-0 rounded-md px-2 py-0.5 text-xs font-medium text-foreground/80 transition-colors hover:bg-accent hover:text-foreground"
					data-queued-send-now
					onclick={onSendNow}
				>
					Send now
				</button>
				<button
					type="button"
					class="shrink-0 rounded-md px-2 py-0.5 text-xs transition-colors hover:bg-accent hover:text-foreground"
					data-queued-remove
					aria-label="Remove queued message"
					onclick={() => onRemove(msg.id)}
				>
					Remove
				</button>
			</div>
		{/each}
	</div>
{/if}
