<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { createSkill, updateSkill, type SkillDetail } from '$lib/ash/api';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button, Field, CONTROL_CLASS, TEXTAREA_CLASS } from '$lib/components/crud';

	let {
		open = $bindable(false),
		skill = null,
		onSaved
	}: {
		open?: boolean;
		skill?: SkillDetail | null;
		onSaved?: (skill: SkillDetail) => void;
	} = $props();

	const isEdit = $derived(skill !== null);

	let name = $state('');
	let displayName = $state('');
	let description = $state('');
	let body = $state('');
	let requestedToolsRaw = $state('');
	let nameError = $state<string | null>(null);
	let saving = $state(false);
	let error = $state<string | null>(null);

	const NAME_RE = /^[a-z0-9-]{1,64}$/;

	// Seed the form each time the dialog opens (edit: from the skill via the old
	// syncForm logic; create: all blank).
	$effect(() => {
		if (!open) return;
		if (skill) {
			name = skill.name;
			displayName = skill.displayName ?? '';
			description = skill.description;
			body = skill.body ?? '';
			requestedToolsRaw = (skill.requestedTools ?? []).join(', ');
		} else {
			name = '';
			displayName = '';
			description = '';
			body = '';
			requestedToolsRaw = '';
		}
		nameError = null;
		error = null;
	});

	const canSave = $derived(
		name.trim() !== '' && NAME_RE.test(name.trim()) && description.trim() !== '' && !saving
	);

	function validateName(): boolean {
		const trimmed = name.trim();
		if (trimmed === '') {
			nameError = 'Name is required.';
			return false;
		}
		if (!NAME_RE.test(trimmed)) {
			nameError = 'Name must be 1-64 lowercase letters, digits, or hyphens (a-z, 0-9, -).';
			return false;
		}
		nameError = null;
		return true;
	}

	function parseTools(raw: string): string[] {
		return raw
			.split(/[,\s]+/)
			.map((t) => t.trim())
			.filter((t) => t.length > 0);
	}

	async function save() {
		if (saving) return;
		if (!validateName()) return;
		saving = true;
		error = null;

		const trimmedName = name.trim();
		const tools = parseTools(requestedToolsRaw);

		if (skill) {
			const result = await updateSkill(skill.id, {
				name: trimmedName,
				displayName: displayName.trim() || null,
				description: description.trim(),
				body: body.trim() || null,
				requestedTools: tools.length > 0 ? tools : null
			});
			saving = false;
			if (!result.success) {
				error = result.errors[0]?.message ?? 'Skill could not be saved';
				return;
			}
			libraryNav.refresh();
			open = false;
			onSaved?.(result.data);
		} else {
			const result = await createSkill({
				name: trimmedName,
				displayName: displayName.trim() || undefined,
				description: description.trim(),
				body: body.trim() || undefined,
				requestedTools: tools.length > 0 ? tools : undefined,
				workspaceId: session.user?.currentWorkspaceId ?? null
			});
			saving = false;
			if (!result.success) {
				error = result.errors[0]?.message ?? 'Skill could not be created';
				return;
			}
			libraryNav.refresh();
			open = false;
			await goto(`${base}/library/skills/${result.data.id}`);
		}
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-2xl" data-testid="skill-form-dialog">
		<Dialog.Header>
			<Dialog.Title>{isEdit ? 'Edit skill' : 'New skill'}</Dialog.Title>
			<Dialog.Description>
				{isEdit
					? 'Update this skill and save your changes.'
					: 'Define a new skill with its name, instructions, and optional tool requirements.'}
			</Dialog.Description>
		</Dialog.Header>

		<form
			class="flex max-h-[70vh] flex-col gap-4 overflow-x-hidden overflow-y-auto"
			onsubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<Field
				label="Name"
				required
				hint="Lowercase letters, digits, and hyphens only (a-z, 0-9, -)"
				error={nameError}
			>
				<!-- svelte-ignore a11y_autofocus — single-purpose dialog -->
				<input
					bind:value={name}
					autofocus
					required
					placeholder="my-skill"
					class={CONTROL_CLASS}
					data-testid="skill-form-name"
					oninput={() => {
						if (nameError) validateName();
					}}
				/>
			</Field>

			<Field label="Display name" hint="Human-readable name shown in the UI">
				<input bind:value={displayName} placeholder="My Skill" class={CONTROL_CLASS} />
			</Field>

			<Field label="Description" required>
				<input
					bind:value={description}
					required
					placeholder="What this skill does"
					class={CONTROL_CLASS}
				/>
			</Field>

			<Field label="Instructions (body)" hint="Full skill instructions, supports Markdown">
				<textarea
					bind:value={body}
					rows="10"
					placeholder="## What this skill does&#10;&#10;Describe the skill..."
					class="{TEXTAREA_CLASS} font-mono"
					data-testid="skill-form-body"
				></textarea>
			</Field>

			<Field
				label="Required tools"
				hint="Comma or space-separated tool names (e.g. bash, web_search)"
			>
				<input
					bind:value={requestedToolsRaw}
					placeholder="bash, web_search"
					class={CONTROL_CLASS}
				/>
			</Field>

			{#if error}
				<p class="text-xs text-destructive">{error}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
				<Button type="submit" disabled={!canSave} data-testid="skill-form-save">
					{saving ? 'Saving…' : isEdit ? 'Save' : 'Create skill'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
