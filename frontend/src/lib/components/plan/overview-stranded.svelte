<script lang="ts">
	import { base } from '$app/paths';
	import { PackageCheck, TriangleAlert, ListChecks } from '@lucide/svelte';
	import type { PlanPage } from '$lib/ash/api';
	import LifecycleBadge from './lifecycle-badge.svelte';

	/**
	 * The anti-stranding alarm: plans that are `done` (every task complete) but were
	 * never delivered. This is the section that makes finished-yet-unshipped work
	 * impossible to forget. Each row links to the plan and offers a Mark-delivered
	 * control (with an optional reference). State is carried by the lifecycle badge
	 * and the amber section frame: warning, not destructive (nothing is broken, the
	 * work just needs closing out). Tokens only, no side-stripe.
	 */
	let {
		plans,
		pending,
		onDeliver
	}: {
		plans: PlanPage[];
		/** Plan ids with a deliver mutation in flight. */
		pending: Set<string>;
		onDeliver: (pageId: string, deliveryRef: string | null) => void;
	} = $props();

	// Which row has its delivery-ref input open + the draft value.
	let openFor = $state<string | null>(null);
	let deliveryRef = $state('');

	function open(id: string) {
		openFor = id;
		deliveryRef = '';
	}
	function cancel() {
		openFor = null;
		deliveryRef = '';
	}
	function confirm(id: string) {
		const ref = deliveryRef.trim();
		openFor = null;
		deliveryRef = '';
		onDeliver(id, ref === '' ? null : ref);
	}
</script>

{#if plans.length > 0}
	<section data-testid="overview-stranded" class="flex flex-col gap-3">
		<div class="flex items-center gap-2">
			<TriangleAlert class="size-4 shrink-0 text-warning" />
			<h2 class="text-sm font-semibold tracking-wide text-foreground uppercase">Needs delivery</h2>
			<span
				class="inline-flex items-center rounded-full bg-warning/10 px-2 py-0.5 text-[11px] font-semibold text-warning tabular-nums"
				data-testid="stranded-count"
			>
				{plans.length}
			</span>
			<span class="text-xs text-muted-foreground"> complete but not yet delivered </span>
		</div>

		<div
			class="flex flex-col divide-y divide-warning/15 overflow-hidden rounded-xl border border-warning/30 bg-warning/[0.04]"
		>
			{#each plans as plan (plan.id)}
				{@const busy = pending.has(plan.id)}
				<div
					class="flex flex-col gap-2 px-3.5 py-3"
					data-testid="stranded-plan"
					data-plan-id={plan.id}
				>
					<div class="flex items-center gap-2">
						<ListChecks class="size-4 shrink-0 text-primary-link" />
						<a
							href="{base}/brain/page/{plan.id}"
							class="min-w-0 flex-1 truncate text-sm font-medium text-foreground hover:underline"
						>
							{plan.title ?? 'Untitled plan'}
						</a>
						<LifecycleBadge lifecycle={plan.lifecycle} class="shrink-0" />
						<button
							type="button"
							data-testid="stranded-deliver"
							disabled={busy}
							onclick={() => open(plan.id)}
							class="inline-flex shrink-0 items-center gap-1 rounded-md border border-dashed border-success/50 px-2 py-1 text-xs font-medium text-success transition-colors hover:border-success hover:bg-success/10 disabled:opacity-50"
						>
							<PackageCheck class="size-3.5" /> Mark delivered
						</button>
					</div>

					{#if openFor === plan.id}
						<div class="flex flex-wrap items-center gap-2" data-testid="stranded-deliver-form">
							<input
								type="text"
								bind:value={deliveryRef}
								placeholder="Delivery reference (optional): release tag, PR link…"
								class="min-w-0 flex-1 rounded-md border bg-background px-2 py-1 text-xs text-foreground placeholder:text-muted-foreground/70 focus:border-success focus:outline-none"
								onkeydown={(e) => {
									if (e.key === 'Enter') confirm(plan.id);
									if (e.key === 'Escape') cancel();
								}}
							/>
							<button
								type="button"
								data-testid="stranded-deliver-confirm"
								disabled={busy}
								onclick={() => confirm(plan.id)}
								class="inline-flex items-center gap-1 rounded-md bg-primary px-2.5 py-1 text-xs font-semibold text-primary-foreground transition-opacity hover:opacity-90 disabled:opacity-50"
							>
								<PackageCheck class="size-3.5" /> Deliver
							</button>
							<button
								type="button"
								onclick={cancel}
								class="rounded-md px-2 py-1 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground"
							>
								Cancel
							</button>
						</div>
					{/if}
				</div>
			{/each}
		</div>
	</section>
{/if}
