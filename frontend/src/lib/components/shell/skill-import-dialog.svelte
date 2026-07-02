<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { uploadSkillBundle } from '$lib/ash/api';
	import { skillsNav } from '$lib/stores/skills-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';

	let file = $state<File | null>(null);
	let busy = $state(false);
	let errors = $state<string[]>([]);

	// Reset internal state when the dialog closes so the next open starts clean.
	$effect(() => {
		if (!skillsNav.importOpen) {
			file = null;
			busy = false;
			errors = [];
		}
	});

	const canImport = $derived(file !== null && !busy);

	async function doImport() {
		if (!canImport || !file) return;
		busy = true;
		errors = [];
		const workspaceId = session.user?.currentWorkspaceId ?? undefined;
		const result = await uploadSkillBundle(file, workspaceId);
		busy = false;
		if (!result.success) {
			errors = result.errors.map((e) => e.message ?? 'Import failed');
			return;
		}
		skillsNav.refresh();
		skillsNav.importOpen = false;
		await goto(`${base}/skills/${result.data.id}`);
	}
</script>

<Dialog.Root bind:open={skillsNav.importOpen}>
	<Dialog.Content class="sm:max-w-md" data-testid="skill-import-dialog">
		<Dialog.Header>
			<Dialog.Title>Import skill</Dialog.Title>
			<Dialog.Description>
				Upload a <code>.zip</code> skill bundle to add it to your library.
			</Dialog.Description>
		</Dialog.Header>

		<form
			class="flex flex-col gap-3"
			onsubmit={(event) => {
				event.preventDefault();
				void doImport();
			}}
		>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Bundle file (.zip)</span>
				<input
					type="file"
					accept=".zip,application/zip"
					data-testid="skill-import-file"
					class="rounded-md border border-input bg-secondary px-3 py-1.5 text-sm file:mr-3 file:cursor-pointer file:rounded file:border-0 file:bg-primary/10 file:px-2 file:py-0.5 file:text-xs file:font-medium file:text-primary"
					onchange={(event) => {
						file = event.currentTarget.files?.[0] ?? null;
					}}
				/>
			</label>

			{#if errors.length > 0}
				<ul class="space-y-0.5 text-xs text-destructive">
					{#each errors as msg, i (i)}
						<li>{msg}</li>
					{/each}
				</ul>
			{/if}

			<Dialog.Footer>
				<Button
					type="button"
					variant="ghost"
					onclick={() => (skillsNav.importOpen = false)}
					disabled={busy}
				>
					Cancel
				</Button>
				<Button type="submit" disabled={!canImport} data-testid="skill-import-submit">
					{#if busy}
						<span
							class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent"
						></span>
						Importing…
					{:else}
						Import
					{/if}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
