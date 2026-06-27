<script lang="ts">
	import { onMount } from 'svelte';
	import { Check, X } from '@lucide/svelte';
	import {
		listUserIntegrations,
		updateIntegrationConfig,
		type IntegrationConfig,
		type UserIntegrationEntry
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import { providerLabel } from '$lib/integrations/provider-label';
	import { Button } from '$lib/components/ui/button';
	import SettingsSection from '$lib/components/crud/section.svelte';

	let integrations = $state<UserIntegrationEntry[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let busy = $state(false);

	onMount(() => void load());

	async function load() {
		const userId = session.user?.id;
		if (!userId) {
			loading = false;
			return;
		}
		const result = await listUserIntegrations(userId);
		if (result.success) integrations = result.data;
		else error = result.errors[0]?.message ?? 'Could not load integrations';
		loading = false;
	}

	async function persist(integration: UserIntegrationEntry, config: IntegrationConfig) {
		busy = true;
		error = null;
		const result = await updateIntegrationConfig(integration.id, config);
		busy = false;
		if (result.success) await load();
		else error = result.errors[0]?.message ?? 'Could not update integration';
	}

	function approve(integration: UserIntegrationEntry, chatId: string) {
		const config = integration.config ?? {};
		void persist(integration, {
			...config,
			pending_approvals: (config.pending_approvals ?? []).filter(
				(entry) => entry.chat_id !== chatId
			),
			allowed_chat_ids: [...new Set([...(config.allowed_chat_ids ?? []), chatId])]
		});
	}

	function deny(integration: UserIntegrationEntry, chatId: string) {
		const config = integration.config ?? {};
		void persist(integration, {
			...config,
			pending_approvals: (config.pending_approvals ?? []).filter(
				(entry) => entry.chat_id !== chatId
			)
		});
	}

	function removeAllowed(integration: UserIntegrationEntry, chatId: string) {
		const config = integration.config ?? {};
		void persist(integration, {
			...config,
			allowed_chat_ids: (config.allowed_chat_ids ?? []).filter((id) => id !== chatId)
		});
	}
</script>

{#if loading}
	<div class="space-y-4" data-testid="settings-integrations-loading">
		{#each [1, 2] as i (i)}
			<div class="h-32 animate-pulse rounded-xl bg-muted/60"></div>
		{/each}
	</div>
{:else}
	<div class="space-y-6" data-testid="settings-integrations">
		{#if error}
			<p class="text-xs text-destructive">{error}</p>
		{/if}

		{#if integrations.length === 0}
			<SettingsSection
				title="Integrations"
				description="External services connected to your account."
			>
				<p class="text-sm text-muted-foreground">
					No integrations yet. Connect a Telegram bot from an agent's settings to start receiving
					messages here.
				</p>
			</SettingsSection>
		{:else}
			{#each integrations as integration (integration.id)}
				{@const config = integration.config ?? {}}
				<SettingsSection
					title={providerLabel(integration.providerKey)}
					description={config.bot_username ? `@${config.bot_username}` : undefined}
					testid="integration-{integration.providerKey}"
				>
					<div class="flex flex-col gap-4">
						<span
							class="w-fit rounded px-1.5 py-0.5 text-[10px] font-medium {integration.status ===
							'active'
								? 'bg-success/15 text-success'
								: 'bg-secondary text-muted-foreground'}"
						>
							{integration.status}
						</span>

						<div>
							<p class="mb-2 text-xs font-medium text-muted-foreground">Pending approvals</p>
							{#if (config.pending_approvals ?? []).length === 0}
								<p class="text-xs text-muted-foreground">None.</p>
							{:else}
								<ul class="flex flex-col gap-1.5" data-testid="integration-approvals">
									{#each config.pending_approvals ?? [] as approval (approval.chat_id)}
										<li class="flex items-center gap-2 rounded-lg border p-2.5">
											<div class="min-w-0 flex-1">
												<p class="truncate text-sm">
													{approval.sender_name || approval.username || 'Unknown'}
												</p>
												<p class="truncate text-xs text-muted-foreground">
													chat {approval.chat_id}
												</p>
											</div>
											<Button
												type="button"
												variant="outline"
												size="sm"
												disabled={busy}
												onclick={() => approval.chat_id && approve(integration, approval.chat_id)}
												data-testid="integration-approve"
											>
												<Check class="size-4" />
												Approve
											</Button>
											<Button
												type="button"
												variant="ghost"
												size="sm"
												disabled={busy}
												onclick={() => approval.chat_id && deny(integration, approval.chat_id)}
												data-testid="integration-deny"
											>
												<X class="size-4" />
												Deny
											</Button>
										</li>
									{/each}
								</ul>
							{/if}
						</div>

						<div>
							<p class="mb-2 text-xs font-medium text-muted-foreground">Allowed chats</p>
							{#if (config.allowed_chat_ids ?? []).length === 0}
								<p class="text-xs text-muted-foreground">None.</p>
							{:else}
								<ul class="flex flex-col gap-1.5" data-testid="integration-allowed">
									{#each config.allowed_chat_ids ?? [] as chatId (chatId)}
										<li class="flex items-center gap-2 rounded-lg border p-2.5">
											<span class="min-w-0 flex-1 truncate font-mono text-xs">{chatId}</span>
											<button
												type="button"
												class="inline-flex size-7 items-center justify-center rounded-md text-destructive transition-colors hover:bg-destructive/10"
												title="Remove"
												disabled={busy}
												onclick={() => removeAllowed(integration, chatId)}
												data-testid="integration-remove-allowed"
											>
												<X class="size-4" />
											</button>
										</li>
									{/each}
								</ul>
							{/if}
						</div>
					</div>
				</SettingsSection>
			{/each}
		{/if}
	</div>
{/if}
