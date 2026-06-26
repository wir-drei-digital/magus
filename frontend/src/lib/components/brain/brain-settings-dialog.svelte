<script lang="ts">
	import { Lock, Users } from '@lucide/svelte';
	import type { BrainSummary } from '$lib/ash/api';
	import { brainNav } from '$lib/stores/brain-nav.svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';

	// Classic BrainSettingsModal: edit title/description/icon/color, plus a
	// workspace-share toggle for workspace brains.
	let { brain = null, open = $bindable(false) }: { brain?: BrainSummary | null; open?: boolean } =
		$props();

	let title = $state('');
	let description = $state('');
	let icon = $state('');
	let color = $state('');
	let saving = $state(false);
	let sharing = $state(false);
	let error = $state<string | null>(null);

	// Seed the form once per open (re-seeds if a different brain is opened).
	let seededFor: string | null = null;
	$effect(() => {
		if (open && brain && seededFor !== brain.id) {
			seededFor = brain.id;
			title = brain.title;
			description = brain.description ?? '';
			icon = brain.icon ?? '';
			color = brain.color ?? '';
			error = null;
		} else if (!open) {
			seededFor = null;
		}
	});

	const canSave = $derived(brain !== null && title.trim() !== '' && !saving);

	async function save() {
		if (!brain || !canSave) return;
		saving = true;
		error = null;
		const ok = await brainNav.updateBrain(brain.id, {
			title: title.trim(),
			description: description.trim() || null,
			icon: icon.trim() || null,
			color: color.trim() || null
		});
		saving = false;
		if (ok) open = false;
		else error = 'Could not save changes.';
	}

	async function toggleShare() {
		if (!brain) return;
		sharing = true;
		await brainNav.toggleShare(brain);
		sharing = false;
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md" data-testid="brain-settings-dialog">
		<Dialog.Header>
			<Dialog.Title>Brain settings</Dialog.Title>
		</Dialog.Header>

		<form
			class="flex flex-col gap-3"
			onsubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Name</span>
				<input
					type="text"
					bind:value={title}
					data-testid="brain-settings-title"
					class="w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60"
				/>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Description</span>
				<textarea
					bind:value={description}
					rows="2"
					data-testid="brain-settings-description"
					class="w-full resize-none rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60"
				></textarea>
			</label>

			<div class="flex gap-3">
				<label class="flex w-20 flex-col gap-1.5 text-sm">
					<span class="text-xs font-medium text-muted-foreground">Icon</span>
					<input
						type="text"
						bind:value={icon}
						placeholder="🧠"
						maxlength="4"
						data-testid="brain-settings-icon"
						class="w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-center text-sm outline-none focus:border-primary/60"
					/>
				</label>
				<label class="flex flex-1 flex-col gap-1.5 text-sm">
					<span class="text-xs font-medium text-muted-foreground">Color</span>
					<input
						type="text"
						bind:value={color}
						placeholder="#8b5cf6"
						data-testid="brain-settings-color"
						class="w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60"
					/>
				</label>
			</div>

			{#if brain?.workspaceId}
				<div
					class="flex items-center justify-between gap-3 rounded-lg border p-3"
					data-testid="brain-settings-share"
				>
					<div class="min-w-0">
						<p class="text-sm font-medium">Workspace sharing</p>
						<p class="text-xs text-muted-foreground">
							{brain.isSharedToWorkspace
								? 'Everyone in this workspace can read and edit.'
								: 'Only people you grant access can see this brain.'}
						</p>
					</div>
					<Button
						type="button"
						variant={brain.isSharedToWorkspace ? 'outline' : 'default'}
						disabled={sharing}
						onclick={() => void toggleShare()}
					>
						{#if brain.isSharedToWorkspace}
							<Lock class="size-4" />
							Make private
						{:else}
							<Users class="size-4" />
							Share
						{/if}
					</Button>
				</div>
			{/if}

			{#if error}
				<p class="text-xs text-destructive" data-testid="brain-settings-error">{error}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
				<Button type="submit" disabled={!canSave} data-testid="brain-settings-save">
					{saving ? 'Saving…' : 'Save'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
