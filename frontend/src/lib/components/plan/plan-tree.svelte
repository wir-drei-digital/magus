<script lang="ts">
	import { base } from '$app/paths';
	import {
		ChevronRight,
		FileText,
		ListChecks,
		Lock,
		Zap,
		PackageCheck,
		Undo2,
		ClipboardList
	} from '@lucide/svelte';
	import LifecycleBadge from './lifecycle-badge.svelte';
	import type { PlanTreeNode } from './plan-tree-store.svelte';

	/**
	 * The unified plan view: spec -> plan -> phases -> tasks, one node per row with
	 * its lifecycle badge, direct ready/blocked counts (plus a rolled-up subtree
	 * ready total), and a deliver / undeliver control on `done` / `delivered`
	 * plans. Nesting is shown by indentation + a disclosure caret; state lives in
	 * the badge + count chips, never a colored side-stripe. Tokens only.
	 *
	 * Decoupled from any one store: it takes the assembled `tree`, the set of plan
	 * ids with a mutation in flight, and deliver/undeliver callbacks, so any caller
	 * (today the brain overview store) can drive it.
	 */
	let {
		tree,
		pending,
		onDeliver,
		onUndeliver
	}: {
		tree: PlanTreeNode[];
		pending: Set<string>;
		onDeliver: (pageId: string, deliveryRef: string | null) => void;
		onUndeliver: (pageId: string) => void;
	} = $props();

	// Collapsed node ids (everything is expanded by default: the whole point is
	// to see the chain). Toggling is local UI state.
	let collapsed = $state<Set<string>>(new Set());
	function toggle(id: string) {
		const next = new Set(collapsed);
		if (next.has(id)) next.delete(id);
		else next.add(id);
		collapsed = next;
	}

	// Per-node delivery-ref draft + which node has its mark-delivered form open.
	let openDeliverFor = $state<string | null>(null);
	let deliveryRef = $state('');

	function openDeliver(id: string) {
		openDeliverFor = id;
		deliveryRef = '';
	}
	function cancelDeliver() {
		openDeliverFor = null;
		deliveryRef = '';
	}
	function confirmDeliver(id: string) {
		const ref = deliveryRef.trim();
		openDeliverFor = null;
		deliveryRef = '';
		onDeliver(id, ref === '' ? null : ref);
	}
</script>

<div data-testid="plan-tree" class="flex flex-col">
	{#if tree.length === 0}
		<div
			class="flex items-center gap-2 rounded-xl border border-dashed border-border/70 px-4 py-8 text-sm text-muted-foreground"
			data-testid="plan-tree-empty"
		>
			<ClipboardList class="size-4 shrink-0 text-muted-foreground/50" />
			No plans or specs in this brain yet.
		</div>
	{:else}
		<div class="overflow-hidden rounded-xl border bg-card/40">
			{#each tree as node (node.id)}
				{@render row(node, 0)}
			{/each}
		</div>
	{/if}
</div>

<!-- One node row, recursively rendering its children one indent deeper. -->
{#snippet row(node: PlanTreeNode, depth: number)}
	{@const hasChildren = node.children.length > 0}
	{@const isCollapsed = collapsed.has(node.id)}
	{@const busy = pending.has(node.id)}
	<div
		class="border-b border-border/60 last:border-b-0"
		data-testid="plan-node"
		data-node-id={node.id}
		data-kind={node.kind}
		data-lifecycle={node.lifecycle}
		data-stranded={node.stranded ? 'true' : undefined}
	>
		<div
			class="flex items-center gap-2 px-3 py-2.5 transition-colors hover:bg-card"
			style="padding-left: {depth * 1.25 + 0.75}rem"
		>
			<!-- Disclosure caret (only when there are children). -->
			{#if hasChildren}
				<button
					type="button"
					data-testid="plan-node-toggle"
					aria-expanded={!isCollapsed}
					aria-label={isCollapsed ? 'Expand' : 'Collapse'}
					onclick={() => toggle(node.id)}
					class="grid size-4 shrink-0 place-items-center rounded text-muted-foreground transition-colors hover:text-foreground"
				>
					<ChevronRight
						class="size-3.5 transition-transform motion-reduce:transition-none {isCollapsed
							? ''
							: 'rotate-90'}"
					/>
				</button>
			{:else}
				<span class="size-4 shrink-0" aria-hidden="true"></span>
			{/if}

			<!-- Kind glyph. -->
			{#if node.kind === 'spec'}
				<FileText class="size-4 shrink-0 text-info" />
			{:else}
				<ListChecks class="size-4 shrink-0 text-primary-link" />
			{/if}

			<!-- Title (links to the page). -->
			<a
				href="{base}/brain/page/{node.id}"
				class="min-w-0 flex-1 truncate text-sm font-medium text-foreground hover:underline"
			>
				{node.title}
			</a>

			<!-- Lifecycle badge (plan/spec). Specs report their raw lifecycle too. -->
			<LifecycleBadge lifecycle={node.lifecycle} class="shrink-0" />

			<!-- Task count chips: ready (claimable) + blocked. -->
			<div class="flex shrink-0 items-center gap-2 text-[11px] text-muted-foreground">
				{#if node.readyCount > 0}
					<span class="inline-flex items-center gap-1" data-testid="plan-node-ready">
						<Zap class="size-3 shrink-0 text-success" />
						<span class="tabular-nums text-foreground">{node.readyCount}</span> ready
					</span>
				{:else if node.totalReadyCount > 0}
					<!-- Nothing claimable here, but the subtree has ready work. -->
					<span class="inline-flex items-center gap-1" data-testid="plan-node-subtree-ready">
						<Zap class="size-3 shrink-0 text-success/60" />
						<span class="tabular-nums">{node.totalReadyCount}</span> below
					</span>
				{/if}
				{#if node.blockedCount > 0}
					<span class="inline-flex items-center gap-1" data-testid="plan-node-blocked">
						<Lock class="size-3 shrink-0 text-warning" />
						<span class="tabular-nums text-foreground">{node.blockedCount}</span> blocked
					</span>
				{/if}
				{#if node.taskCount > 0}
					<span class="tabular-nums text-muted-foreground/70"
						>{node.taskCount} task{node.taskCount === 1 ? '' : 's'}</span
					>
				{/if}
			</div>

			<!-- Deliver / undeliver affordance (plan pages only). -->
			{#if node.stranded}
				<button
					type="button"
					data-testid="plan-node-deliver"
					disabled={busy}
					onclick={() => openDeliver(node.id)}
					class="inline-flex shrink-0 items-center gap-1 rounded-md border border-dashed border-success/50 px-2 py-1 text-xs font-medium text-success transition-colors hover:border-success hover:bg-success/10 disabled:opacity-50"
				>
					<PackageCheck class="size-3.5" /> Mark delivered
				</button>
			{:else if node.lifecycle === 'delivered'}
				<button
					type="button"
					data-testid="plan-node-undeliver"
					disabled={busy}
					onclick={() => onUndeliver(node.id)}
					title={node.deliveryRef ? `Delivered: ${node.deliveryRef}` : 'Delivered'}
					class="inline-flex shrink-0 items-center gap-1 rounded-md px-2 py-1 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground disabled:opacity-50"
				>
					<Undo2 class="size-3.5" /> Undeliver
				</button>
			{/if}
		</div>

		<!-- Inline mark-delivered form: optional delivery reference. -->
		{#if openDeliverFor === node.id}
			<div
				class="flex flex-wrap items-center gap-2 bg-success/5 px-3 py-2"
				style="padding-left: {depth * 1.25 + 2.5}rem"
				data-testid="plan-node-deliver-form"
			>
				<input
					type="text"
					bind:value={deliveryRef}
					placeholder="Delivery reference (optional): release tag, PR link…"
					class="min-w-0 flex-1 rounded-md border bg-background px-2 py-1 text-xs text-foreground placeholder:text-muted-foreground/70 focus:border-success focus:outline-none"
					onkeydown={(e) => {
						if (e.key === 'Enter') confirmDeliver(node.id);
						if (e.key === 'Escape') cancelDeliver();
					}}
				/>
				<button
					type="button"
					data-testid="plan-node-deliver-confirm"
					disabled={busy}
					onclick={() => confirmDeliver(node.id)}
					class="inline-flex items-center gap-1 rounded-md bg-primary px-2.5 py-1 text-xs font-semibold text-primary-foreground transition-opacity hover:opacity-90 disabled:opacity-50"
				>
					<PackageCheck class="size-3.5" /> Deliver
				</button>
				<button
					type="button"
					onclick={cancelDeliver}
					class="rounded-md px-2 py-1 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground"
				>
					Cancel
				</button>
			</div>
		{/if}

		<!-- Children, one indent deeper. -->
		{#if hasChildren && !isCollapsed}
			{#each node.children as child (child.id)}
				{@render row(child, depth + 1)}
			{/each}
		{/if}
	</div>
{/snippet}
