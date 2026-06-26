<script lang="ts">
	import { onMount } from 'svelte';
	import { base } from '$app/paths';
	import { Files } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import SettingsSection from '$lib/components/crud/section.svelte';
	import { creditStatus, type CreditStatus } from '$lib/ash/api';
	import { formatFileSize } from '$lib/files/format';

	let status = $state<CreditStatus | null>(null);
	let loading = $state(true);

	const percent = $derived.by(() => {
		if (!status || status.storageLimit === null || status.storageLimit === 0) return null;
		return Math.min(100, Math.round((status.storageUsed / status.storageLimit) * 100));
	});

	onMount(() => {
		void creditStatus().then((result) => {
			if (result.success) status = result.data;
			loading = false;
		});
	});
</script>

{#if loading}
	<div
		class="h-40 animate-pulse rounded-xl bg-muted/60"
		data-testid="settings-storage-loading"
	></div>
{:else}
	<div class="space-y-6" data-testid="settings-storage">
		<SettingsSection title="Storage" description="Space used by your uploaded files.">
			{#if status}
				<div class="flex items-baseline justify-between text-sm">
					<span class="font-medium" data-testid="storage-used">
						{formatFileSize(status.storageUsed)} used
					</span>
					<span class="text-xs text-muted-foreground">
						{status.storageLimit === null
							? 'Unlimited'
							: `of ${formatFileSize(status.storageLimit)}`}
					</span>
				</div>
				{#if percent !== null}
					<div class="mt-2 h-2 overflow-hidden rounded-full bg-secondary">
						<div
							class="h-full rounded-full bg-primary transition-[width]"
							style="width: {percent}%"
						></div>
					</div>
				{/if}
			{:else}
				<p class="text-sm text-muted-foreground">Usage is currently unavailable.</p>
			{/if}

			<div class="mt-4">
				<a href="{base}/files">
					<Button variant="outline" data-testid="storage-manage-files">
						<Files class="size-4" />
						Manage files
					</Button>
				</a>
			</div>
		</SettingsSection>
	</div>
{/if}
