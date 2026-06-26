<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { createWorkspace } from '$lib/ash/api';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';

	let { open = $bindable(false) }: { open?: boolean } = $props();

	let name = $state('');
	let slug = $state('');
	let slugEdited = $state(false);
	let saving = $state(false);
	let error = $state<string | null>(null);

	$effect(() => {
		if (!open) {
			name = '';
			slug = '';
			slugEdited = false;
			saving = false;
			error = null;
		}
	});

	// Classic parity: auto-derive the slug from the name until the user edits
	// the slug field directly.
	function slugify(value: string): string {
		return value
			.toLowerCase()
			.replace(/[^a-z0-9\s-]/g, '')
			.replace(/\s+/g, '-')
			.replace(/^-+|-+$/g, '');
	}

	function onNameInput() {
		if (!slugEdited) slug = slugify(name);
	}

	const canCreate = $derived(name.trim() !== '' && slug.trim().length >= 2 && !saving);

	async function create() {
		if (!canCreate) return;
		saving = true;
		error = null;
		const result = await createWorkspace({ name: name.trim(), slug: slug.trim() });
		saving = false;
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Workspace could not be created';
			return;
		}
		workbench.upsertWorkspace({
			id: result.data.id,
			name: result.data.name,
			slug: result.data.slug
		});
		open = false;
		await goto(`${base}/workspaces/${result.data.slug}`);
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md" data-testid="create-workspace-dialog">
		<Dialog.Header>
			<Dialog.Title>New workspace</Dialog.Title>
			<Dialog.Description>
				A shared space for conversations, files, prompts, and agents.
			</Dialog.Description>
		</Dialog.Header>

		<form
			class="flex flex-col gap-3"
			onsubmit={(event) => {
				event.preventDefault();
				void create();
			}}
		>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Workspace name</span>
				<!-- svelte-ignore a11y_autofocus — single-purpose creation dialog -->
				<input
					type="text"
					bind:value={name}
					oninput={onNameInput}
					autofocus
					placeholder="e.g. Acme Engineering"
					data-testid="create-workspace-name"
					class="w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60"
				/>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">URL slug</span>
				<input
					type="text"
					bind:value={slug}
					oninput={() => (slugEdited = true)}
					placeholder="acme-engineering"
					data-testid="create-workspace-slug"
					class="w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60"
				/>
				<span class="text-[11px] text-muted-foreground">
					Lowercase letters, numbers, and hyphens. Used in URLs.
				</span>
			</label>

			{#if error}
				<p class="text-xs text-destructive" data-testid="create-workspace-error">{error}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
				<Button type="submit" disabled={!canCreate} data-testid="create-workspace-submit">
					{saving ? 'Creating…' : 'Create workspace'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
