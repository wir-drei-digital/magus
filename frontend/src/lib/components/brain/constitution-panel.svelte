<script lang="ts">
	/**
	 * Editable brain constitution: `brain.instructions`, the always-on
	 * markdown guide the agent reads on every turn (see
	 * `Magus.Brain.Guide.for_page/4`). A power-user affordance, collapsed by
	 * default, so most viewers never see it. A thin view over
	 * {@link ConstitutionPanelStore}, which owns all collapse/edit/dirty/save
	 * logic so it's unit-testable without mounting Svelte.
	 */
	import { ChevronDown, ChevronUp, ScrollText } from '@lucide/svelte';
	import { untrack } from 'svelte';
	import { updateBrain } from '$lib/ash/api';
	import Markdown from '$lib/components/chat/markdown.svelte';
	import { Button } from '$lib/components/ui/button';
	import { ConstitutionPanelStore } from './constitution-panel-store.svelte';

	let { brainId, instructions }: { brainId: string; instructions: string | null } = $props();

	async function save(draft: string): Promise<boolean> {
		const result = await updateBrain(brainId, { instructions: draft || null });
		return result.success;
	}

	let store = $state(untrack(() => new ConstitutionPanelStore(brainId, instructions, save)));

	// Re-seed the store when a different brain (or freshly loaded instructions)
	// is handed in, without discarding the just-computed initial default.
	let seededFor: string | null = null;
	$effect(() => {
		const id = brainId;
		const current = instructions;
		if (seededFor === null) {
			seededFor = id;
			return;
		}
		if (seededFor !== id) {
			seededFor = id;
			store = new ConstitutionPanelStore(id, current, save);
		}
	});
</script>

<div class="flex flex-col border-t" data-testid="constitution-panel">
	<button
		type="button"
		class="flex items-center gap-2 px-1 py-2 text-left"
		data-testid="constitution-panel-toggle"
		aria-expanded={!store.collapsed}
		onclick={() => store.toggle()}
	>
		<ScrollText class="size-4 shrink-0 text-primary-link" />
		<span class="flex-1 text-sm font-semibold text-foreground">Constitution</span>
		<span class="text-xs text-muted-foreground">Always-on guidance for the agent</span>
		{#if store.collapsed}
			<ChevronDown class="size-3.5 shrink-0 text-muted-foreground" />
		{:else}
			<ChevronUp class="size-3.5 shrink-0 text-muted-foreground" />
		{/if}
	</button>

	{#if !store.collapsed}
		<div class="flex flex-col gap-2 pb-3">
			{#if store.editing}
				<textarea
					value={store.draft}
					oninput={(event) => store.setDraft(event.currentTarget.value)}
					rows="8"
					placeholder="e.g. Every content page must declare a type. Link related pages. Ask before restructuring."
					data-testid="constitution-panel-textarea"
					class="w-full resize-y rounded-md border border-input bg-secondary px-2.5 py-2 font-mono text-xs outline-none focus:border-primary/60"
				></textarea>
				<div class="flex items-center gap-2">
					<Button
						type="button"
						size="sm"
						disabled={!store.dirty || store.saveState === 'saving'}
						onclick={() => void store.save()}
						data-testid="constitution-panel-save"
					>
						{store.saveState === 'saving' ? 'Saving…' : 'Save'}
					</Button>
					<Button
						type="button"
						size="sm"
						variant="ghost"
						onclick={() => store.cancelEdit()}
						data-testid="constitution-panel-cancel"
					>
						Cancel
					</Button>
					{#if store.saveState === 'error'}
						<span class="text-xs text-destructive" data-testid="constitution-panel-error">
							Could not save. Try again.
						</span>
					{/if}
				</div>
			{:else if store.draft.trim() === ''}
				<button
					type="button"
					class="rounded-md border border-dashed border-input px-3 py-4 text-left text-xs text-muted-foreground hover:border-primary/60 hover:text-foreground"
					data-testid="constitution-panel-empty"
					onclick={() => store.startEdit()}
				>
					No constitution yet. Click to write one, or let the agent propose it as it works in this
					brain.
				</button>
			{:else}
				<button
					type="button"
					class="rounded-md border border-transparent px-2.5 py-1 text-left hover:border-input hover:bg-secondary/50"
					data-testid="constitution-panel-preview"
					title="Click to edit"
					onclick={() => store.startEdit()}
				>
					<Markdown text={store.draft} />
				</button>
			{/if}
		</div>
	{/if}
</div>
