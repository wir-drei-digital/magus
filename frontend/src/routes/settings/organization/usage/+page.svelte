<script lang="ts">
	import { Section } from '$lib/components/crud';
	import { getOrgAdmin } from '$lib/components/organizations/context';
	import { orgUsageOverview, type OrgUsageOverview } from '$lib/ash/api';
	import { formatCents } from '$lib/billing/format';
	import { formatCap, seatLabel, usageRows } from '$lib/organizations/usage';

	const ctx = getOrgAdmin();

	let overview = $state<OrgUsageOverview | null>(null);
	let loaded = $state(false);

	// Load once the layout has resolved the org id. The action scopes the visible
	// member set server-side (owner: all rows; a member: only their own), so the
	// view renders whatever it returns without re-filtering.
	let loadedFor: string | null = null;
	$effect(() => {
		const id = ctx.org?.id;
		if (!id || loadedFor === id) return;
		loadedFor = id;
		void orgUsageOverview(id).then((result) => {
			if (result.success) overview = result.data;
			loaded = true;
		});
	});

	const rows = $derived(overview ? usageRows(overview) : []);
</script>

<div class="flex flex-col gap-5">
	<Section
		title="Pooled spend"
		description="Combined credit spend across everyone in this organization."
		testid="org-usage-pooled"
	>
		<div class="grid grid-cols-2 gap-6">
			<div>
				<p class="text-2xl font-bold tabular-nums">
					{formatCents(overview?.pooledSpentCents ?? 0)}
				</p>
				<p class="text-xs text-muted-foreground">Spent this period</p>
			</div>
			<div>
				<p class="text-2xl font-bold tabular-nums">{overview?.seatCount ?? 0}</p>
				<p class="text-xs text-muted-foreground">{seatLabel(overview?.seatCount ?? 0)}</p>
			</div>
		</div>
	</Section>

	<Section
		title="Per-member spend"
		description="Credit spend this period and each member's monthly cap."
		testid="org-usage-members"
	>
		{#if !loaded}
			<div class="space-y-2" data-testid="org-usage-loading">
				{#each [1, 2, 3] as i (i)}
					<div class="h-9 animate-pulse rounded-lg bg-muted/60"></div>
				{/each}
			</div>
		{:else if rows.length === 0}
			<p class="text-sm text-muted-foreground">No members to show.</p>
		{:else}
			<div class="overflow-x-auto">
				<table class="w-full text-sm" data-testid="org-usage-table">
					<thead>
						<tr class="border-b text-left text-xs text-muted-foreground">
							<th class="py-2 pr-4 font-medium">Member</th>
							<th class="py-2 pr-4 text-right font-medium">Spent</th>
							<th class="py-2 text-right font-medium">Monthly cap</th>
						</tr>
					</thead>
					<tbody>
						{#each rows as row (row.userId)}
							<tr class="border-b last:border-0" data-testid="org-usage-row">
								<td class="truncate py-2 pr-4">{row.name}</td>
								<td class="py-2 pr-4 text-right tabular-nums">{formatCents(row.spentCents)}</td>
								<td class="py-2 text-right tabular-nums">{formatCap(row.capCents)}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</Section>
</div>
