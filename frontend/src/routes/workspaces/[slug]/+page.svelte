<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import {
		deactivateWorkspace,
		updateWorkspace,
		workspaceAgents,
		type AgentSummary
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import {
		Section as SettingsSection,
		Button,
		ToggleSwitch,
		Field,
		CONTROL_CLASS
	} from '$lib/components/crud';
	import { getWorkspaceAdmin } from '$lib/components/workspaces/context';

	const ctx = getWorkspaceAdmin();

	// Form state, seeded from the loaded workspace (re-seeded if it reloads).
	let name = $state('');
	let isActive = $state(true);
	let defaultAgentId = $state<string | null>(null);
	let seededFor = $state<string | null>(null);

	$effect(() => {
		const ws = ctx.workspace;
		if (ws && seededFor !== ws.id) {
			seededFor = ws.id;
			name = ws.name;
			isActive = ws.isActive;
			defaultAgentId = ws.defaultAgentId;
		}
	});

	let agents = $state<AgentSummary[]>([]);
	let agentsFor = $state<string | null>(null);
	$effect(() => {
		const ws = ctx.workspace;
		if (ws && agentsFor !== ws.id) {
			agentsFor = ws.id;
			void workspaceAgents(ws.id).then((result) => {
				if (result.success) agents = result.data;
			});
		}
	});

	let saving = $state(false);
	let message = $state<{ kind: 'ok' | 'error'; text: string } | null>(null);

	const dirty = $derived(
		ctx.workspace !== null &&
			(name.trim() !== ctx.workspace.name ||
				isActive !== ctx.workspace.isActive ||
				defaultAgentId !== ctx.workspace.defaultAgentId)
	);

	async function save() {
		if (!ctx.workspace || saving || !dirty) return;
		saving = true;
		message = null;
		const result = await updateWorkspace(ctx.workspace.id, {
			name: name.trim(),
			isActive,
			defaultAgentId
		});
		saving = false;
		if (result.success) {
			message = { kind: 'ok', text: 'Saved' };
			workbench.upsertWorkspace({
				id: result.data.id,
				name: result.data.name,
				slug: result.data.slug
			});
			await ctx.reloadWorkspace();
		} else {
			message = { kind: 'error', text: result.errors[0]?.message ?? 'Could not save' };
		}
	}

	// Delete (deactivate) with type-to-confirm — mirrors the classic guard.
	let confirmName = $state('');
	let deleting = $state(false);
	let deleteError = $state<string | null>(null);
	const confirmMatches = $derived(!!ctx.workspace && confirmName.trim() === ctx.workspace.name);

	async function destroy() {
		if (!ctx.workspace || !confirmMatches || deleting) return;
		deleting = true;
		deleteError = null;
		const id = ctx.workspace.id;
		const result = await deactivateWorkspace(id);
		deleting = false;
		if (!result.success) {
			deleteError = result.errors[0]?.message ?? 'Could not delete workspace';
			return;
		}
		workbench.removeWorkspace(id);
		if (session.user?.currentWorkspaceId === id) await session.selectWorkspace(null);
		await goto(`${base}/chat`);
	}
</script>

<div class="flex flex-col gap-5">
	<SettingsSection
		title="General"
		description="Name and defaults for this workspace."
		testid="workspace-general"
	>
		<form
			class="flex flex-col gap-4"
			onsubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<Field label="Workspace name">
				<input
					type="text"
					bind:value={name}
					maxlength="80"
					class={CONTROL_CLASS}
					data-testid="workspace-name"
				/>
			</Field>

			<div class="flex items-center justify-between gap-4 text-sm">
				<span>Workspace active</span>
				<ToggleSwitch
					checked={isActive}
					onchange={(next) => (isActive = next)}
					label="Workspace active"
					testid="workspace-active"
				/>
			</div>

			<Field label="Default agent">
				<select
					bind:value={defaultAgentId}
					class={CONTROL_CLASS}
					data-testid="workspace-default-agent"
				>
					<option value={null}>None (use default)</option>
					{#each agents as agent (agent.id)}
						<option value={agent.id}>{agent.name}</option>
					{/each}
				</select>
			</Field>

			<div class="flex items-center gap-3 pt-1">
				<Button type="submit" disabled={!dirty || saving} data-testid="workspace-save">
					{saving ? 'Saving…' : 'Save changes'}
				</Button>
				{#if message}
					<span
						class="text-xs {message.kind === 'ok' ? 'text-muted-foreground' : 'text-destructive'}"
						data-testid="workspace-save-message"
					>
						{message.text}
					</span>
				{/if}
			</div>
		</form>
	</SettingsSection>

	<SettingsSection title="Details" testid="workspace-details">
		<dl class="flex flex-col gap-2 text-sm">
			<div class="flex items-center justify-between">
				<dt class="text-muted-foreground">Slug</dt>
				<dd class="font-mono text-xs">{ctx.workspace?.slug}</dd>
			</div>
			<div class="flex items-center justify-between">
				<dt class="text-muted-foreground">Members</dt>
				<dd>{ctx.members.filter((member) => member.isActive).length}</dd>
			</div>
		</dl>
	</SettingsSection>

	<SettingsSection
		variant="danger"
		title="Delete workspace"
		description="Permanently removes the workspace and all its conversations, files, prompts, agents, and member access. This cannot be undone."
		testid="workspace-danger"
	>
		<form
			class="flex flex-col gap-2"
			onsubmit={(event) => {
				event.preventDefault();
				void destroy();
			}}
		>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs text-muted-foreground">
					Type <span class="font-mono">{ctx.workspace?.name}</span> to confirm
				</span>
				<input
					type="text"
					bind:value={confirmName}
					autocomplete="off"
					class={CONTROL_CLASS}
					data-testid="workspace-delete-confirm"
				/>
			</label>
			{#if deleteError}
				<p class="text-xs text-destructive">{deleteError}</p>
			{/if}
			<div>
				<Button
					type="submit"
					variant="destructive"
					disabled={!confirmMatches || deleting}
					data-testid="workspace-delete"
				>
					{deleting ? 'Deleting…' : 'Delete workspace'}
				</Button>
			</div>
		</form>
	</SettingsSection>
</div>
