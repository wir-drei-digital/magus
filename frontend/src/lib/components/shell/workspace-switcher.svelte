<script lang="ts">
	import { base } from '$app/paths';
	import { Check, ChevronDown, Plus, Settings, User } from '@lucide/svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { cn } from '$lib/utils.js';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import CreateWorkspaceDialog from './create-workspace-dialog.svelte';

	const currentWorkspace = $derived(
		workbench.workspaces.find((workspace) => workspace.id === session.user?.currentWorkspaceId) ??
			null
	);
	const currentWorkspaceName = $derived(currentWorkspace?.name ?? 'Personal');

	let createOpen = $state(false);
</script>

<!-- Our workbench trigger design; the popover follows the shadcn
     team-switcher anatomy (label, items with check, separators, actions). -->
<DropdownMenu.Root>
	<DropdownMenu.Trigger
		class="flex w-full items-center gap-2.5 rounded-xl border border-input bg-secondary py-1.5 pl-1.5 pr-2 transition-colors hover:bg-accent/60"
		data-testid="workspace-selector"
	>
		<span
			class="flex size-8 items-center justify-center rounded-lg bg-primary text-sm font-bold text-primary-foreground shadow-sm"
		>
			{currentWorkspaceName.slice(0, 1).toUpperCase()}
		</span>
		<span class="min-w-0 flex-1 truncate text-left text-sm font-semibold">
			{currentWorkspaceName}
		</span>
		<ChevronDown class="mr-1 size-4 text-muted-foreground opacity-50" />
	</DropdownMenu.Trigger>
	<DropdownMenu.Content class="w-64 rounded-lg" align="start" side="bottom" sideOffset={4}>
		<DropdownMenu.Label class="text-xs text-muted-foreground">Workspaces</DropdownMenu.Label>
		<DropdownMenu.Item onSelect={() => void session.selectWorkspace(null)} class="gap-2 p-2">
			<div class="flex size-6 items-center justify-center rounded-md border">
				<User class="size-4 shrink-0 text-muted-foreground" />
			</div>
			<span class="flex-1">Personal</span>
			{#if !session.user?.currentWorkspaceId}<Check class="size-3.5" />{/if}
		</DropdownMenu.Item>
		{#each workbench.workspaces as workspace (workspace.id)}
			<DropdownMenu.Item
				onSelect={() => void session.selectWorkspace(workspace.id)}
				class="gap-2 p-2"
			>
				<div
					class="flex size-6 items-center justify-center rounded-md border text-xs font-semibold"
				>
					{workspace.name.slice(0, 1).toUpperCase()}
				</div>
				<span class="flex-1 truncate">{workspace.name}</span>
				{#if session.user?.currentWorkspaceId === workspace.id}
					<Check class="size-3.5" />
				{/if}
			</DropdownMenu.Item>
		{/each}
		<DropdownMenu.Separator />
		{#if currentWorkspace}
			<DropdownMenu.Item>
				{#snippet child({ props })}
					<!-- Merge, don't clobber: the spread carries the item's base classes
					     (incl. `flex items-center`); a plain class attribute would override
					     them and stack the icon above the label. -->
					<a
						{...props}
						href="{base}/workspaces/{currentWorkspace.slug}"
						data-testid="workspace-settings-link"
						class={cn((props as { class?: string }).class, 'gap-2 p-2')}
					>
						<div class="flex size-6 items-center justify-center rounded-md border">
							<Settings class="size-4 shrink-0 text-muted-foreground" />
						</div>
						<span class="flex-1">Workspace settings</span>
					</a>
				{/snippet}
			</DropdownMenu.Item>
		{/if}
		<DropdownMenu.Item
			onSelect={() => (createOpen = true)}
			class="gap-2 p-2"
			data-testid="new-workspace"
		>
			<div class="flex size-6 items-center justify-center rounded-md border bg-background">
				<Plus class="size-4 shrink-0" />
			</div>
			<span class="font-medium text-muted-foreground">New workspace</span>
		</DropdownMenu.Item>
	</DropdownMenu.Content>
</DropdownMenu.Root>

<CreateWorkspaceDialog bind:open={createOpen} />
