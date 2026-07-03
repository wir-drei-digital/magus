<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import {
		addPromptTags,
		createPrompt,
		getOrCreateTag,
		getPrompt,
		listTags,
		removePromptTag,
		updatePrompt,
		type PromptDetail,
		type PromptType,
		type TagEntry
	} from '$lib/ash/api';
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
	let type = $state<PromptType>('user');
	let saving = $state(false);
	let error = $state<string | null>(null);

	// Tag chips: existing tags carry an id; freshly typed ones resolve to an id
	// (get-or-create, scoped to the prompt's workspace or personal) on save.
	let tags = $state<{ id: string | null; name: string }[]>([]);
	let tagInput = $state('');
	let availableTags = $state<TagEntry[]>([]);

	// Seed the form each time the dialog opens (edit: from the prompt; create:
	// blank plus the optional initialBody prefill).
	$effect(() => {
		if (!open) return;
		if (prompt) {
			name = prompt.name;
			content = prompt.content;
			description = prompt.description ?? '';
			type = prompt.type;
			tags = prompt.tags.map((tag) => ({ id: tag.id, name: tag.name }));
		} else {
			name = '';
			content = initialBody;
			description = '';
			type = 'user';
			tags = [];
		}
		tagInput = '';
		error = null;
		void listTags().then((result) => {
			if (result.success) availableTags = result.data;
		});
	});

	// The tag scope follows the prompt: its workspace when editing, the active
	// workspace when creating.
	const tagWorkspaceId = $derived(
		prompt ? prompt.workspaceId : (session.user?.currentWorkspaceId ?? null)
	);

	const tagSuggestions = $derived(
		availableTags.filter(
			(tag) =>
				(tag.workspaceId ?? null) === tagWorkspaceId &&
				!tags.some((added) => added.name.toLowerCase() === tag.name.toLowerCase())
		)
	);

	function addTag(raw: string) {
		const trimmed = raw.trim().replace(/^#/, '');
		if (trimmed === '') return;
		if (tags.some((tag) => tag.name.toLowerCase() === trimmed.toLowerCase())) {
			tagInput = '';
			return;
		}
		const existing = availableTags.find(
			(tag) =>
				tag.name.toLowerCase() === trimmed.toLowerCase() &&
				(tag.workspaceId ?? null) === tagWorkspaceId
		);
		tags = [...tags, { id: existing?.id ?? null, name: existing?.name ?? trimmed }];
		tagInput = '';
	}

	function onTagKeydown(event: KeyboardEvent) {
		if (event.key === 'Enter' || event.key === ',') {
			event.preventDefault();
			addTag(tagInput);
		} else if (event.key === 'Backspace' && tagInput === '' && tags.length > 0) {
			tags = tags.slice(0, -1);
		}
	}

	/** Resolve every chip to a tag id, creating missing tags in scope. */
	async function resolveTagIds(): Promise<string[] | null> {
		const ids: string[] = [];
		for (const tag of tags) {
			if (tag.id) {
				ids.push(tag.id);
				continue;
			}
			const result = await getOrCreateTag(tag.name, tagWorkspaceId);
			if (!result.success) {
				error = result.errors[0]?.message ?? `Tag "${tag.name}" could not be created`;
				return null;
			}
			ids.push(result.data.id);
		}
		return ids;
	}

	async function syncTags(promptId: string, original: { id: string }[]): Promise<boolean> {
		const tagIds = await resolveTagIds();
		if (tagIds === null) return false;
		const current = new Set(tagIds);
		const before = new Set(original.map((tag) => tag.id));
		const toAdd = tagIds.filter((id) => !before.has(id));
		const toRemove = [...before].filter((id) => !current.has(id));
		if (toAdd.length > 0) await addPromptTags(promptId, toAdd);
		for (const id of toRemove) await removePromptTag(promptId, id);
		return true;
	}

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
				description: description.trim() || undefined
			});
			if (!result.success) {
				saving = false;
				error = result.errors[0]?.message ?? 'Prompt could not be saved';
				return;
			}
			const synced = await syncTags(prompt.id, prompt.tags);
			saving = false;
			if (!synced) return;
			// Refetch so onSaved sees the updated tag set, not the pre-sync one.
			const fresh = await getPrompt(prompt.id);
			libraryNav.refresh();
			open = false;
			onSaved?.(fresh.success ? fresh.data : result.data);
		} else {
			const result = await createPrompt({
				name: name.trim(),
				content,
				type,
				description: description.trim() || undefined,
				workspaceId: session.user?.currentWorkspaceId ?? null
			});
			if (!result.success) {
				saving = false;
				error = result.errors[0]?.message ?? 'Prompt could not be created';
				return;
			}
			// The prompt exists either way; a failed tag resolve shouldn't strand
			// the dialog over an already-created prompt.
			await syncTags(result.data.id, []);
			saving = false;
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
			class="flex max-h-[70vh] flex-col gap-3 overflow-x-hidden overflow-y-auto"
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

			<div class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Tags</span>
				<div
					class="flex flex-wrap items-center gap-1.5 rounded-lg border border-input bg-secondary px-2 py-1.5"
					data-testid="prompt-form-tags"
				>
					{#each tags as tag, index (tag.name)}
						<span
							class="flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary"
						>
							#{tag.name}
							<button
								type="button"
								aria-label="Remove tag {tag.name}"
								class="transition-colors hover:text-foreground"
								onclick={() => (tags = tags.filter((_, i) => i !== index))}
							>
								×
							</button>
						</span>
					{/each}
					<input
						bind:value={tagInput}
						list="prompt-form-tag-suggestions"
						placeholder={tags.length === 0 ? 'Add tags (Enter to add)…' : ''}
						data-testid="prompt-form-tag-input"
						class="min-w-24 flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
						onkeydown={onTagKeydown}
						onblur={() => addTag(tagInput)}
					/>
				</div>
				<datalist id="prompt-form-tag-suggestions">
					{#each tagSuggestions as suggestion (suggestion.id)}
						<option value={suggestion.name}></option>
					{/each}
				</datalist>
				<span class="text-[11px] text-muted-foreground">
					{tagWorkspaceId
						? 'Tags are shared with this workspace.'
						: 'Personal tags — only you can see them.'}
				</span>
			</div>

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
