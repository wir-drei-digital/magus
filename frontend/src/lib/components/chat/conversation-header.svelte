<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { onMount } from 'svelte';
	import { Bot, EllipsisVertical, ListChecks, Star } from '@lucide/svelte';
	import type { AgentSummary, CompanionSpec } from '$lib/ash/api';
	import { cachedMyAgents } from '$lib/chat/catalog';
	import type { ConversationStore } from '$lib/chat/conversation-store.svelte';
	import { relativeTime } from '$lib/time';
	import { workbench } from '$lib/stores/workbench.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import RightRail from './rail/right-rail.svelte';
	import ShareConversationDialog from './share-conversation-dialog.svelte';
	import { confirmAction } from '$lib/stores/confirm.svelte';
	import { toast } from '$lib/stores/toast.svelte';

	let {
		store,
		onCompanionRequest
	}: {
		store: ConversationStore;
		onCompanionRequest?: (spec: CompanionSpec) => void;
	} = $props();

	const conversationId = $derived(store.conversationId);

	const conversation = $derived(workbench.conversation(conversationId));

	let agents = $state<AgentSummary[]>([]);
	let shareOpen = $state(false);
	let editing = $state(false);
	let titleDraft = $state('');
	let titleInput = $state<HTMLInputElement | null>(null);

	const agent = $derived(
		agents.find((entry) => entry.id === conversation?.customAgentId) ??
			agents.find((entry) => entry.isDefault) ??
			null
	);

	onMount(() => {
		void cachedMyAgents().then((result) => {
			if (result.success) agents = result.data;
		});
	});

	function startRename() {
		titleDraft = conversation?.title ?? '';
		editing = true;
		requestAnimationFrame(() => titleInput?.select());
	}

	async function commitRename() {
		// Enter commits and removes the input, which fires blur — guard so the
		// blur-after-Enter path is a no-op instead of a duplicate RPC.
		if (!editing) return;
		editing = false;
		const title = titleDraft.trim();
		if (!title || title === conversation?.title) return;
		await workbench.renameConversation(conversationId, title);
	}

	async function archive() {
		const ok = await confirmAction({
			title: 'Archive conversation?',
			description: 'It moves to your archive — you can undo this.',
			confirmLabel: 'Archive'
		});
		if (!ok) return;
		const archived = await workbench.archiveConversation(conversationId);
		if (!archived) return;
		toast('Conversation archived', {
			action: { label: 'Undo', run: () => void workbench.restoreConversation(conversationId) }
		});
		await goto(`${base}/chat`);
	}
</script>

<div
	class="flex shrink-0 items-center justify-between gap-3 border-b bg-background/60 py-2.5 pr-4 pl-14 md:pl-4"
	data-testid="conversation-header"
>
	<div class="flex min-w-0 items-center gap-3">
		<span
			class="flex size-8 shrink-0 items-center justify-center rounded-full border border-input bg-secondary text-sm"
			aria-hidden="true"
		>
			{#if agent?.icon}
				{agent.icon}
			{:else}
				<Bot class="size-4 text-muted-foreground" />
			{/if}
		</span>
		<div class="min-w-0">
			{#if editing}
				<input
					bind:this={titleInput}
					bind:value={titleDraft}
					class="w-full max-w-md rounded-md border border-input bg-secondary px-2 py-0.5 text-sm outline-none focus:border-primary/60"
					data-testid="conversation-title-input"
					onkeydown={(event) => {
						if (event.key === 'Enter') void commitRename();
						if (event.key === 'Escape') editing = false;
					}}
					onblur={() => void commitRename()}
				/>
			{:else}
				<button
					type="button"
					class="block max-w-full truncate text-sm font-semibold hover:underline"
					data-testid="conversation-title"
					title="Rename conversation"
					onclick={startRename}
				>
					{conversation?.title ?? 'Untitled conversation'}
				</button>
			{/if}
			<p class="truncate text-xs text-muted-foreground">
				{agent?.name ?? 'Assistant'}{#if conversation?.updatedAt}
					· {relativeTime(conversation.updatedAt)}{/if}
			</p>
		</div>
	</div>

	<div class="flex shrink-0 items-center gap-1.5">
		<button
			type="button"
			class="wb-pill-btn wb-pill-btn-square shrink-0 {conversation?.isFavorited
				? '!text-favorite'
				: ''}"
			data-testid="conversation-favorite"
			aria-label={conversation?.isFavorited ? 'Unfavorite' : 'Favorite'}
			onclick={() => void workbench.toggleFavorite(conversationId)}
		>
			<Star class="size-3.5 {conversation?.isFavorited ? 'fill-favorite' : ''}" />
		</button>

		{#if onCompanionRequest}
			<button
				type="button"
				class="wb-pill-btn wb-pill-btn-square shrink-0"
				data-testid="conversation-tasks"
				aria-label="Tasks"
				title="Tasks"
				onclick={() => onCompanionRequest?.({ type: 'tasks', id: conversationId })}
			>
				<ListChecks class="size-3.5" />
			</button>
		{/if}

		<RightRail {store} {onCompanionRequest} />

		<DropdownMenu.Root>
			<DropdownMenu.Trigger
				class="wb-pill-btn wb-pill-btn-square shrink-0"
				data-testid="conversation-menu"
				aria-label="Conversation actions"
			>
				<EllipsisVertical class="size-3.5" />
			</DropdownMenu.Trigger>
			<DropdownMenu.Content align="end">
				<DropdownMenu.Item onSelect={startRename}>Rename</DropdownMenu.Item>
				<DropdownMenu.Item data-testid="conversation-share" onSelect={() => (shareOpen = true)}>
					Share…
				</DropdownMenu.Item>
				<DropdownMenu.Separator />
				<DropdownMenu.Item variant="destructive" onSelect={() => void archive()}>
					Archive
				</DropdownMenu.Item>
			</DropdownMenu.Content>
		</DropdownMenu.Root>
	</div>
</div>

<ShareConversationDialog {conversationId} bind:open={shareOpen} />
