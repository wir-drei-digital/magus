<script lang="ts">
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import { confirmStore } from '$lib/stores/confirm.svelte';

	const pending = $derived(confirmStore.pending);
</script>

<Dialog.Root
	open={pending !== null}
	onOpenChange={(open) => {
		if (!open) confirmStore.cancel();
	}}
>
	<Dialog.Content class="sm:max-w-sm" data-testid="confirm-dialog">
		{#if pending}
			<Dialog.Header>
				<Dialog.Title>{pending.title}</Dialog.Title>
				{#if pending.description}
					<Dialog.Description>{pending.description}</Dialog.Description>
				{/if}
			</Dialog.Header>
			<Dialog.Footer>
				<Button variant="ghost" data-testid="confirm-cancel" onclick={() => confirmStore.cancel()}>
					{pending.cancelLabel ?? 'Cancel'}
				</Button>
				<Button
					variant={pending.destructive === false ? 'default' : 'destructive'}
					data-testid="confirm-accept"
					onclick={() => confirmStore.confirm()}
				>
					{pending.confirmLabel ?? 'Confirm'}
				</Button>
			</Dialog.Footer>
		{/if}
	</Dialog.Content>
</Dialog.Root>
