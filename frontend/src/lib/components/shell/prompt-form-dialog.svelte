<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { createPrompt, updatePrompt, type PromptDetail, type PromptType } from '$lib/ash/api';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';
	import { CONTROL_CLASS, TEXTAREA_CLASS } from '$lib/components/crud';

	let {
		open = $bindable(false),
		prompt = null,
		initialBody = '',
		onSaved
	}: {
		open?: boolean;
		prompt?: PromptDetail | null;
		initialBody?: string;
		onSaved?: (prompt: PromptDetail) => void;
	} = $props();

	const isEdit = $derived(prompt !== null);

	let name = $state('');
	let content = $state('');
	let description = $state('');
	let additionalInformation = $state('');
	let type = $state<PromptType>('user');
	let saving = $state(false);
	let error = $state<string | null>(null);

	// Seed the form each time the dialog opens (edit: from the prompt; create:
	// blank plus the optional initialBody prefill).
	$effect(() => {
		if (!open) return;
		if (prompt) {
			name = prompt.name;
			content = prompt.content;
			description = prompt.description ?? '';
			additionalInformation = prompt.additionalInformation ?? '';
			type = prompt.type;
		} else {
			name = '';
			content = initialBody;
			description = '';
			additionalInformation = '';
			type = 'user';
		}
		error = null;
	});

	const canSave = $derived(name.trim() !== '' && content.trim() !== '' && !saving);

	async function save() {
		if (!canSave) return;
		saving = true;
		error = null;

		if (prompt) {
			const result = await updatePrompt(prompt.id, {
				name: name.trim(),
				content,
				type,
				description: description.trim() || undefined,
				additionalInformation: additionalInformation.trim() || undefined
			});
			saving = false;
			if (!result.success) {
				error = result.errors[0]?.message ?? 'Prompt could not be saved';
				return;
			}
			libraryNav.refresh();
			open = false;
			onSaved?.(result.data);
		} else {
			const result = await createPrompt({
				name: name.trim(),
				content,
				type,
				description: description.trim() || undefined,
				additionalInformation: additionalInformation.trim() || undefined,
				workspaceId: session.user?.currentWorkspaceId ?? null
			});
			saving = false;
			if (!result.success) {
				error = result.errors[0]?.message ?? 'Prompt could not be created';
				return;
			}
			libraryNav.refresh();
			open = false;
			await goto(`${base}/library/prompts/${result.data.id}`);
		}
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-2xl" data-testid="prompt-form-dialog">
		<Dialog.Header>
			<Dialog.Title>{isEdit ? 'Edit prompt' : 'New prompt'}</Dialog.Title>
			<Dialog.Description>
				{isEdit
					? 'Update this prompt and save your changes.'
					: 'Create a reusable prompt for your library.'}
			</Dialog.Description>
		</Dialog.Header>

		<form
			class="flex max-h-[70vh] flex-col gap-3 overflow-y-auto"
			onsubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Name</span>
				<!-- svelte-ignore a11y_autofocus — single-purpose dialog -->
				<input
					type="text"
					bind:value={name}
					autofocus
					required
					data-testid="prompt-form-name"
					class={CONTROL_CLASS}
				/>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Type</span>
				<select bind:value={type} data-testid="prompt-form-type" class="{CONTROL_CLASS} w-48">
					<option value="user">User prompt</option>
					<option value="system">System prompt</option>
				</select>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Description</span>
				<input
					bind:value={description}
					class={CONTROL_CLASS}
					data-testid="prompt-form-description"
				/>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Additional information</span>
				<textarea
					bind:value={additionalInformation}
					rows="2"
					data-testid="prompt-form-additional"
					class={TEXTAREA_CLASS}
				></textarea>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Content</span>
				<textarea
					bind:value={content}
					required
					rows="10"
					data-testid="prompt-form-content"
					class="{TEXTAREA_CLASS} font-mono"
				></textarea>
			</label>

			{#if error}
				<p class="text-xs text-destructive">{error}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
				<Button type="submit" disabled={!canSave} data-testid="prompt-form-save">
					{saving ? 'Saving…' : isEdit ? 'Save' : 'Create'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
