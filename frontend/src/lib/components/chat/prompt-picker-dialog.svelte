<script lang="ts">
	import { Search, SquareTerminal } from '@lucide/svelte';
	import {
		getPrompt,
		incrementPromptUseCount,
		myPrompts,
		workspacePrompts,
		type PromptSummary
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import * as Dialog from '$lib/components/ui/dialog';

	let {
		open = $bindable(false),
		onInsert
	}: {
		open?: boolean;
		/** Inserts the prompt's content into the composer. */
		onInsert: (content: string) => void;
	} = $props();

	let prompts = $state<PromptSummary[]>([]);
	let query = $state('');

	$effect(() => {
		if (!open) return;
		const workspaceId = session.user?.currentWorkspaceId ?? null;
		const request = workspaceId ? workspacePrompts(workspaceId) : myPrompts();
		void request.then((result) => {
			if (result.success) prompts = result.data;
		});
	});

	const filtered = $derived(
		prompts.filter(
			(prompt) => query === '' || prompt.name.toLowerCase().includes(query.toLowerCase())
		)
	);

	async function pick(prompt: PromptSummary) {
		open = false;
		// Content isn't in the summary selection; fetch on pick (classic
		// increments use count on insert too).
		const result = await getPrompt(prompt.id);
		if (!result.success) return;
		onInsert(result.data.content);
		void incrementPromptUseCount(prompt.id);
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="max-w-md">
		<Dialog.Header>
			<Dialog.Title>Insert prompt</Dialog.Title>
		</Dialog.Header>

		<label
			class="flex items-center gap-2 rounded-md border border-input bg-secondary px-2 py-1.5 text-sm"
		>
			<Search class="size-4 shrink-0 text-muted-foreground" />
			<input
				bind:value={query}
				placeholder="Search prompts"
				class="min-w-0 flex-1 bg-transparent outline-none"
			/>
		</label>

		<div class="wb-scroll max-h-72 space-y-0.5 overflow-y-auto" data-testid="prompt-picker">
			{#each filtered as prompt (prompt.id)}
				<button
					type="button"
					class="flex w-full items-start gap-2 rounded-md px-2 py-1.5 text-left text-sm transition-colors hover:bg-accent/60"
					data-testid="prompt-picker-option"
					onclick={() => void pick(prompt)}
				>
					<SquareTerminal class="mt-0.5 size-3.5 shrink-0 text-muted-foreground" />
					<span class="min-w-0">
						<span class="block truncate font-medium">{prompt.name}</span>
						{#if prompt.description}
							<span class="block truncate text-xs text-muted-foreground">
								{prompt.description}
							</span>
						{/if}
					</span>
				</button>
			{:else}
				<p class="p-2 text-sm text-muted-foreground">
					{query ? 'No matches.' : 'No prompts in your library yet.'}
				</p>
			{/each}
		</div>
	</Dialog.Content>
</Dialog.Root>
