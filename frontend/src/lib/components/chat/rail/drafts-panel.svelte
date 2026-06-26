<script lang="ts">
	import { onMount } from 'svelte';
	import { FileText, Trash2 } from '@lucide/svelte';
	import {
		conversationDrafts,
		deleteDraft,
		type CompanionSpec,
		type DraftDetail
	} from '$lib/ash/api';
	import { relativeTime } from '$lib/time';

	let {
		conversationId,
		onCompanionRequest
	}: {
		conversationId: string;
		onCompanionRequest?: (spec: CompanionSpec) => void;
	} = $props();

	let drafts = $state<DraftDetail[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);

	onMount(() => {
		void refresh();
	});

	async function refresh() {
		const result = await conversationDrafts(conversationId);
		if (result.success) drafts = result.data;
		loading = false;
	}

	function open(draft: DraftDetail) {
		onCompanionRequest?.({ type: 'draft', id: draft.id });
	}

	async function remove(draft: DraftDetail) {
		error = null;
		const result = await deleteDraft(draft.id);
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Could not delete draft';
			return;
		}
		drafts = drafts.filter((entry) => entry.id !== draft.id);
	}
</script>

<div class="flex min-h-0 flex-1 flex-col" data-testid="rail-drafts-panel">
	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto p-1.5">
		{#if error}
			<p class="p-2 text-xs text-destructive">{error}</p>
		{/if}
		{#if loading}
			<div class="space-y-2 p-1">
				{#each [1, 2] as i (i)}
					<div class="h-10 animate-pulse rounded-md bg-muted"></div>
				{/each}
			</div>
		{:else if drafts.length === 0}
			<p class="p-2 text-xs text-muted-foreground">No drafts yet. Ask the AI to write a draft.</p>
		{:else}
			<ul class="space-y-0.5">
				{#each drafts as draft (draft.id)}
					<li
						class="group flex items-center gap-2 rounded-md px-2 py-1.5 transition-colors hover:bg-accent/60"
					>
						<button
							type="button"
							class="flex min-w-0 flex-1 items-center gap-2 text-left"
							data-testid="rail-draft"
							onclick={() => open(draft)}
						>
							<FileText class="size-3.5 shrink-0 text-muted-foreground" />
							<span class="min-w-0 flex-1">
								<span class="block truncate text-xs font-medium">{draft.title}</span>
								<span class="block text-[11px] text-muted-foreground">
									v{draft.version} · {relativeTime(draft.updatedAt)}
								</span>
							</span>
						</button>
						<button
							type="button"
							class="shrink-0 rounded-md p-1 text-muted-foreground opacity-0 transition-opacity hover:text-destructive group-hover:opacity-100"
							title="Delete draft"
							data-testid="rail-delete-draft"
							onclick={() => void remove(draft)}
						>
							<Trash2 class="size-3.5" />
						</button>
					</li>
				{/each}
			</ul>
		{/if}
	</div>
</div>
