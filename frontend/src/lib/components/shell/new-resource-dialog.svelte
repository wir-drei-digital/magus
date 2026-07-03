<script lang="ts" module>
	export type NewResourceKind = 'agent' | 'brain';
</script>

<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { createCustomAgent } from '$lib/ash/api';
	import { invalidateAgentCatalog } from '$lib/chat/catalog';
	import { agentsNav } from '$lib/stores/agents-nav.svelte';
	import { brainNav } from '$lib/stores/brain-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';
	import { CONTROL_CLASS, TEXTAREA_CLASS } from '$lib/components/crud';

	let {
		kind,
		open = $bindable(false),
		initialBody = ''
	}: {
		kind: NewResourceKind;
		open?: boolean;
		/** Prefill for the content/instructions field (create-prompt-from-message). */
		initialBody?: string;
	} = $props();

	const COPY: Record<NewResourceKind, { title: string; description: string; nameLabel: string }> = {
		agent: {
			title: 'New agent',
			description: 'Create a custom agent you can mention and automate.',
			nameLabel: 'Name'
		},
		brain: {
			title: 'New brain',
			description: 'Create a knowledge space for connected pages.',
			nameLabel: 'Title'
		}
	};

	let name = $state('');
	let body = $state('');
	let saving = $state(false);
	let error = $state<string | null>(null);

	$effect(() => {
		if (open) {
			body = initialBody;
		} else {
			name = '';
			body = '';
			error = null;
		}
	});

	const canCreate = $derived(name.trim() !== '' && !saving);

	async function create() {
		if (!canCreate) return;
		saving = true;
		error = null;
		const workspaceId = session.user?.currentWorkspaceId ?? null;

		if (kind === 'agent') {
			const result = await createCustomAgent({
				name: name.trim(),
				instructions: body.trim() || undefined,
				workspaceId
			});
			saving = false;
			if (!result.success) {
				error = result.errors[0]?.message ?? 'Agent could not be created';
				return;
			}
			agentsNav.refresh();
			invalidateAgentCatalog();
			open = false;
			await goto(`${base}/agents/${result.data.id}`);
		} else {
			const brain = await brainNav.createBrain(name.trim());
			saving = false;
			if (!brain) {
				error = 'Brain could not be created';
				return;
			}
			open = false;
		}
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md" data-testid="new-resource-dialog">
		<Dialog.Header>
			<Dialog.Title>{COPY[kind].title}</Dialog.Title>
			<Dialog.Description>{COPY[kind].description}</Dialog.Description>
		</Dialog.Header>

		<form
			class="flex flex-col gap-3"
			onsubmit={(event) => {
				event.preventDefault();
				void create();
			}}
		>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">{COPY[kind].nameLabel}</span>
				<!-- svelte-ignore a11y_autofocus — single-purpose creation dialog -->
				<input
					type="text"
					bind:value={name}
					autofocus
					data-testid="new-resource-name"
					class={CONTROL_CLASS}
				/>
			</label>

			{#if kind === 'agent'}
				<label class="flex flex-col gap-1.5 text-sm">
					<span class="text-xs font-medium text-muted-foreground">Instructions (optional)</span>
					<textarea
						bind:value={body}
						rows="4"
						placeholder="What should this agent do?"
						data-testid="new-resource-content"
						class={TEXTAREA_CLASS}
					></textarea>
				</label>
			{/if}

			{#if error}
				<p class="text-xs text-destructive">{error}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
				<Button type="submit" disabled={!canCreate} data-testid="new-resource-create">
					{saving ? 'Creating…' : 'Create'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
