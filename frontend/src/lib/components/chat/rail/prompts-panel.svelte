<script lang="ts">
	import { onMount } from 'svelte';
	import { Play, X } from '@lucide/svelte';
	import {
		activateConversationPrompt,
		conversationSettings,
		deactivateConversationPrompt,
		getConversation,
		getPrompt,
		incrementPromptUseCount,
		myFavoritePrompts,
		myPrompts,
		type PromptSummary,
		type PromptType
	} from '$lib/ash/api';
	import { workbench } from '$lib/stores/workbench.svelte';

	let {
		conversationId,
		onInsert,
		onActivated
	}: {
		conversationId: string;
		onInsert: (text: string) => void;
		/** Called after a system prompt was activated (the rail closes itself). */
		onActivated?: () => void;
	} = $props();

	let tab = $state<'my' | 'favorites'>('my');
	let search = $state('');
	let typeFilter = $state<'all' | PromptType>('all');
	let prompts = $state<PromptSummary[]>([]);
	let favorites = $state<PromptSummary[]>([]);
	let activePrompt = $state<{ id: string; name: string } | null>(null);
	let loading = $state(true);
	let error = $state<string | null>(null);

	onMount(() => {
		void Promise.all([myPrompts(), myFavoritePrompts(), conversationSettings(conversationId)]).then(
			([mine, favs, settings]) => {
				if (mine.success) prompts = mine.data;
				if (favs.success) favorites = favs.data;
				if (settings.success) activePrompt = settings.data.activeSystemPrompt;
				loading = false;
			}
		);
	});

	const visible = $derived.by(() => {
		const source = tab === 'my' ? prompts : favorites;
		const query = search.trim().toLowerCase();
		return source.filter(
			(prompt) =>
				(typeFilter === 'all' || prompt.type === typeFilter) &&
				(query === '' ||
					prompt.name.toLowerCase().includes(query) ||
					(prompt.description ?? '').toLowerCase().includes(query))
		);
	});

	/** User prompts: fetch content, bump use count, hand text to the composer. */
	async function insert(prompt: PromptSummary) {
		error = null;
		const detail = await getPrompt(prompt.id);
		if (!detail.success) {
			error = detail.errors[0]?.message ?? 'Could not load prompt';
			return;
		}
		void incrementPromptUseCount(prompt.id);
		onInsert(detail.data.content);
	}

	/**
	 * System prompts: set as the conversation's active system prompt. The
	 * server may also apply the prompt's model/mode, so the nav row refetches.
	 */
	async function activate(prompt: PromptSummary) {
		error = null;
		const result = await activateConversationPrompt(conversationId, prompt.id);
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Could not activate prompt';
			return;
		}
		activePrompt = result.data.activeSystemPrompt;
		void incrementPromptUseCount(prompt.id);
		void getConversation(conversationId).then((conversation) => {
			if (conversation.success) workbench.upsertConversation(conversation.data);
		});
		onActivated?.();
	}

	async function deactivate() {
		error = null;
		const result = await deactivateConversationPrompt(conversationId);
		if (result.success) activePrompt = result.data.activeSystemPrompt;
	}
</script>

<div class="flex min-h-0 flex-1 flex-col" data-testid="rail-prompts-panel">
	<div class="space-y-2 border-b p-2.5">
		<div class="flex items-center gap-1 text-xs">
			<button
				type="button"
				class="rounded-md px-2 py-1 font-medium transition-colors {tab === 'my'
					? 'bg-secondary text-foreground'
					: 'text-muted-foreground hover:text-foreground'}"
				onclick={() => (tab = 'my')}
			>
				My prompts
			</button>
			<button
				type="button"
				class="rounded-md px-2 py-1 font-medium transition-colors {tab === 'favorites'
					? 'bg-secondary text-foreground'
					: 'text-muted-foreground hover:text-foreground'}"
				onclick={() => (tab = 'favorites')}
			>
				Favorites
			</button>
			<select
				bind:value={typeFilter}
				class="ml-auto rounded-md border border-input bg-secondary px-1.5 py-1 text-xs outline-none"
				aria-label="Filter by type"
			>
				<option value="all">All</option>
				<option value="system">System</option>
				<option value="user">User</option>
			</select>
		</div>
		<input
			type="search"
			bind:value={search}
			placeholder="Search prompts…"
			class="w-full rounded-md border border-input bg-secondary px-2 py-1.5 text-xs outline-none focus:border-primary/60"
			data-testid="rail-prompts-search"
		/>
		{#if activePrompt}
			<div
				class="flex items-center gap-2 rounded-md border border-primary/40 bg-primary/10 px-2 py-1.5 text-xs"
				data-testid="rail-active-prompt"
			>
				<span class="min-w-0 flex-1 truncate">
					Active: <span class="font-medium">{activePrompt.name}</span>
				</span>
				<button
					type="button"
					class="shrink-0 text-muted-foreground hover:text-foreground"
					aria-label="Deactivate system prompt"
					data-testid="rail-deactivate-prompt"
					onclick={() => void deactivate()}
				>
					<X class="size-3.5" />
				</button>
			</div>
		{/if}
		{#if error}
			<p class="text-xs text-destructive">{error}</p>
		{/if}
	</div>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto p-1.5">
		{#if loading}
			<div class="space-y-2 p-1">
				{#each [1, 2, 3] as i (i)}
					<div class="h-10 animate-pulse rounded-md bg-muted"></div>
				{/each}
			</div>
		{:else if visible.length === 0}
			<p class="p-2 text-xs text-muted-foreground">No prompts found.</p>
		{:else}
			<ul class="space-y-0.5">
				{#each visible as prompt (prompt.id)}
					<li
						class="group flex items-start gap-2 rounded-md px-2 py-1.5 transition-colors hover:bg-accent/60"
					>
						<span class="min-w-0 flex-1">
							<span class="flex items-center gap-1.5">
								<span class="min-w-0 truncate text-xs font-medium">{prompt.name}</span>
								<span
									class="shrink-0 rounded border border-input px-1 text-[9px] uppercase text-muted-foreground"
								>
									{prompt.type}
								</span>
							</span>
							{#if prompt.description}
								<span class="block truncate text-[11px] text-muted-foreground">
									{prompt.description}
								</span>
							{/if}
						</span>
						{#if prompt.type === 'user'}
							<button
								type="button"
								class="shrink-0 rounded-md p-1 text-muted-foreground opacity-0 transition-opacity hover:text-foreground group-hover:opacity-100"
								title="Insert into composer"
								data-testid="rail-insert-prompt"
								onclick={() => void insert(prompt)}
							>
								<Play class="size-3.5" />
							</button>
						{:else if activePrompt?.id !== prompt.id}
							<button
								type="button"
								class="shrink-0 rounded-md p-1 text-muted-foreground opacity-0 transition-opacity hover:text-foreground group-hover:opacity-100"
								title="Activate as system prompt"
								data-testid="rail-activate-prompt"
								onclick={() => void activate(prompt)}
							>
								<Play class="size-3.5" />
							</button>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}
	</div>
</div>
