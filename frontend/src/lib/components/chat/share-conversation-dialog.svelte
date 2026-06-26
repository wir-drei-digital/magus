<script lang="ts">
	import { Check, Copy, Globe, Link, Lock, Users } from '@lucide/svelte';
	import {
		conversationShareLinks,
		createShareLink,
		disableConversationMultiplayer,
		enableConversationMultiplayer,
		revokeShareLink,
		type ShareLink
	} from '$lib/ash/api';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';

	let {
		conversationId,
		open = $bindable(false)
	}: {
		conversationId: string;
		open?: boolean;
	} = $props();

	const conversation = $derived(workbench.conversation(conversationId));

	let links = $state<ShareLink[]>([]);
	let loading = $state(true);
	let accessType = $state<'public' | 'authenticated'>('public');
	let label = $state('');
	let busy = $state(false);
	let error = $state<string | null>(null);
	let copiedId = $state<string | null>(null);

	$effect(() => {
		if (!open) {
			error = null;
			label = '';
			return;
		}
		loading = true;
		void conversationShareLinks(conversationId).then((result) => {
			if (result.success) links = result.data;
			loading = false;
		});
	});

	function shareUrl(link: ShareLink): string {
		return `${location.origin}/shared/${link.token}`;
	}

	async function copyLink(link: ShareLink) {
		try {
			await navigator.clipboard.writeText(shareUrl(link));
			copiedId = link.id;
			setTimeout(() => (copiedId = copiedId === link.id ? null : copiedId), 1500);
		} catch {
			// Clipboard denied; the URL stays visible for manual copy.
		}
	}

	async function create() {
		if (busy) return;
		busy = true;
		error = null;
		const result = await createShareLink({
			conversationId,
			accessType,
			...(label.trim() ? { label: label.trim() } : {})
		});
		busy = false;
		if (result.success) {
			links = [result.data, ...links];
			label = '';
		} else {
			error = result.errors[0]?.message ?? 'Link could not be created';
		}
	}

	async function revoke(link: ShareLink) {
		const result = await revokeShareLink(link.id);
		if (result.success) links = links.filter((entry) => entry.id !== link.id);
	}

	async function toggleMultiplayer() {
		if (!conversation || busy) return;
		busy = true;
		const result = conversation.isMultiplayer
			? await disableConversationMultiplayer(conversationId)
			: await enableConversationMultiplayer(conversationId);
		busy = false;
		if (result.success) workbench.upsertConversation(result.data);
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-lg" data-testid="share-dialog">
		<Dialog.Header>
			<Dialog.Title>Share conversation</Dialog.Title>
			<Dialog.Description>
				Read-only links for viewers, collaboration for participants.
			</Dialog.Description>
		</Dialog.Header>

		<div class="flex flex-col gap-5">
			<!-- Collaboration (multiplayer) -->
			<section class="flex items-center justify-between gap-3">
				<div class="min-w-0">
					<p class="flex items-center gap-1.5 text-sm font-medium">
						<Users class="size-4 text-muted-foreground" />
						Collaboration
					</p>
					<p class="text-xs text-muted-foreground">
						{conversation?.isMultiplayer
							? 'Participants can be invited and write messages.'
							: 'Turn on to invite participants into this conversation.'}
					</p>
				</div>
				<button
					type="button"
					class="wb-pill-btn shrink-0 {conversation?.isMultiplayer ? 'wb-pill-btn-active' : ''}"
					data-testid="share-multiplayer-toggle"
					disabled={busy}
					onclick={() => void toggleMultiplayer()}
				>
					{conversation?.isMultiplayer ? 'Enabled' : 'Enable'}
				</button>
			</section>

			<!-- Read-only links -->
			<section class="flex flex-col gap-2">
				<p class="flex items-center gap-1.5 text-sm font-medium">
					<Link class="size-4 text-muted-foreground" />
					Read-only links
				</p>
				<p class="text-xs text-muted-foreground">
					Anyone with these links can view this conversation.
				</p>

				{#if !loading && links.length > 0}
					<ul class="flex flex-col gap-1.5" data-testid="share-link-list">
						{#each links as link (link.id)}
							<li class="flex items-center gap-2 rounded-lg border border-input px-2.5 py-1.5">
								{#if link.accessType === 'public'}
									<Globe class="size-3.5 shrink-0 text-muted-foreground" />
								{:else}
									<Lock class="size-3.5 shrink-0 text-muted-foreground" />
								{/if}
								<span class="min-w-0 flex-1">
									<span class="block truncate text-xs font-medium">
										{link.label ||
											(link.accessType === 'public' ? 'Public link' : 'Signed-in only')}
									</span>
									<span class="block truncate text-[10px] text-muted-foreground">
										{shareUrl(link)}
									</span>
								</span>
								<button
									type="button"
									class="wb-pill-btn wb-pill-btn-square shrink-0 {copiedId === link.id
										? '!text-success'
										: ''}"
									title="Copy link"
									data-testid="share-link-copy"
									onclick={() => void copyLink(link)}
								>
									{#if copiedId === link.id}<Check class="size-3.5" />{:else}<Copy
											class="size-3.5"
										/>{/if}
								</button>
								<button
									type="button"
									class="wb-pill-btn shrink-0 hover:!text-destructive"
									data-testid="share-link-revoke"
									onclick={() => void revoke(link)}
								>
									Revoke
								</button>
							</li>
						{/each}
					</ul>
				{/if}

				<form
					class="flex items-end gap-2"
					onsubmit={(event) => {
						event.preventDefault();
						void create();
					}}
				>
					<label class="flex min-w-0 flex-1 flex-col gap-1 text-xs">
						<span class="font-medium text-muted-foreground">Label (optional)</span>
						<input
							type="text"
							bind:value={label}
							placeholder="e.g. For the team wiki"
							class="rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60"
						/>
					</label>
					<label class="flex shrink-0 flex-col gap-1 text-xs">
						<span class="font-medium text-muted-foreground">Access</span>
						<select
							bind:value={accessType}
							class="rounded-md border border-input bg-secondary px-2 py-[7px] text-sm outline-none focus:border-primary/60"
						>
							<option value="public">Public</option>
							<option value="authenticated">Signed-in only</option>
						</select>
					</label>
					<Button type="submit" disabled={busy} data-testid="share-link-create">Create link</Button>
				</form>
				{#if error}
					<p class="text-xs text-destructive">{error}</p>
				{/if}
			</section>
		</div>
	</Dialog.Content>
</Dialog.Root>
