<script lang="ts">
	import SettingsSection from '$lib/components/crud/section.svelte';
	import { getWorkspaceAdmin } from '$lib/components/workspaces/context';
	import { workspaceMemberUsage, type MemberUsageEntry } from '$lib/ash/api';
	import { relativeTime } from '$lib/time';

	const ctx = getWorkspaceAdmin();

	let usage = $state<MemberUsageEntry[]>([]);
	let usageLoaded = $state(false);

	// Load once the layout has resolved the workspace id (admin-gated server-side).
	let loadedFor: string | null = null;
	$effect(() => {
		const id = ctx.workspace?.id;
		if (!id || loadedFor === id) return;
		loadedFor = id;
		void workspaceMemberUsage(id).then((result) => {
			if (result.success) usage = result.data;
			usageLoaded = true;
		});
	});

	function formatBytes(bytes: number): string {
		if (bytes < 1024) return `${bytes} B`;
		const units = ['KB', 'MB', 'GB', 'TB'];
		let value = bytes / 1024;
		let unit = 0;
		while (value >= 1024 && unit < units.length - 1) {
			value /= 1024;
			unit += 1;
		}
		return `${value.toFixed(value >= 10 ? 0 : 1)} ${units[unit]}`;
	}

	const activeCount = $derived(ctx.members.filter((member) => member.isActive).length);
	const invitedCount = $derived(ctx.members.filter((member) => member.status === 'invited').length);

	// Join the server-aggregated rows (already sorted by last-active desc) with
	// each member's display name.
	const rows = $derived(
		usage.map((entry) => {
			const member = ctx.members.find((m) => m.user?.id === entry.userId);
			return {
				...entry,
				name: member?.user?.displayName ?? member?.user?.email ?? 'Unknown'
			};
		})
	);
</script>

<div class="flex flex-col gap-5">
	<SettingsSection
		title="Storage"
		description="Files uploaded to this workspace."
		testid="workspace-usage-storage"
	>
		<p class="text-2xl font-bold">{formatBytes(ctx.workspace?.storageUsageBytes ?? 0)}</p>
	</SettingsSection>

	<SettingsSection title="Members" testid="workspace-usage-members">
		<div class="grid grid-cols-2 gap-6">
			<div>
				<p class="text-2xl font-bold">{activeCount}</p>
				<p class="text-xs text-muted-foreground">Active members</p>
			</div>
			<div>
				<p class="text-2xl font-bold">{invitedCount}</p>
				<p class="text-xs text-muted-foreground">Pending invites</p>
			</div>
		</div>
	</SettingsSection>

	<SettingsSection
		title="Per-member usage"
		description="Credits consumed today, storage used, and last activity."
		testid="workspace-usage-members-breakdown"
	>
		{#if !usageLoaded}
			<div class="space-y-2" data-testid="workspace-usage-loading">
				{#each [1, 2, 3] as i (i)}
					<div class="h-9 animate-pulse rounded-lg bg-muted/60"></div>
				{/each}
			</div>
		{:else if rows.length === 0}
			<p class="text-sm text-muted-foreground">No active members.</p>
		{:else}
			<div class="overflow-x-auto">
				<table class="w-full text-sm" data-testid="member-usage-table">
					<thead>
						<tr class="border-b text-left text-xs text-muted-foreground">
							<th class="py-2 pr-4 font-medium">Member</th>
							<th class="py-2 pr-4 text-right font-medium">Credits today</th>
							<th class="py-2 pr-4 text-right font-medium">Storage</th>
							<th class="py-2 text-right font-medium">Last active</th>
						</tr>
					</thead>
					<tbody>
						{#each rows as row (row.userId)}
							<tr class="border-b last:border-0" data-testid="member-usage-row">
								<td class="truncate py-2 pr-4">{row.name}</td>
								<td class="py-2 pr-4 text-right tabular-nums">{row.credits}</td>
								<td class="py-2 pr-4 text-right tabular-nums">{formatBytes(row.storageBytes)}</td>
								<td class="py-2 text-right text-muted-foreground">
									{row.lastActiveAt ? relativeTime(row.lastActiveAt) : 'Never'}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</SettingsSection>
</div>
