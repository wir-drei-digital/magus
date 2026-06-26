<script lang="ts">
	import { CreditCard } from '@lucide/svelte';
	import { moneyUsageStatus, type MoneyUsageStatus } from '$lib/ash/api';
	import { notificationFeed } from '$lib/stores/notifications.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';

	let status = $state<MoneyUsageStatus | null>(null);

	async function refresh() {
		const result = await moneyUsageStatus();
		if (result.success) status = result.data;
	}

	// Initial load plus live refresh: re-runs on mount and whenever the user
	// channel bumps usageRevision after a billable response, mirroring the
	// classic shell that recomputes its gauge on the usage-changed broadcast.
	$effect(() => {
		void notificationFeed.usageRevision;
		void refresh();
	});

	// Mirror MagusWeb.Workbench.Live.Usage: a spend cap drives the gauge; an
	// uncapped (postpaid opt-out, in good standing) sub has nothing to fill, so
	// percentage stays 0 and the panel just shows the spent amount.
	const cap = $derived(status?.capCents ?? 0);
	const capped = $derived(cap > 0);
	const percentage = $derived(
		capped && status ? Math.min(100, Math.round((status.spentCents / cap) * 1000) / 10) : 0
	);
	const nearCap = $derived(capped && percentage >= 80);

	type BarState = 'active' | 'warning' | 'error' | 'inactive';

	const bars = $derived.by((): BarState[] => {
		if (percentage >= 90) return ['error', 'error', 'error'];
		if (percentage >= 75) return ['warning', 'warning', 'warning'];
		if (percentage >= 40) return ['active', 'active', 'inactive'];
		return ['active', 'inactive', 'inactive'];
	});

	const BAR_CLASS: Record<BarState, string> = {
		active: 'bg-success',
		warning: 'bg-warning',
		error: 'bg-destructive',
		inactive: 'bg-muted-foreground/30'
	};

	const progressClass = $derived(
		percentage >= 90 ? 'bg-destructive' : percentage >= 75 ? 'bg-warning' : 'bg-success'
	);

	const chf = (cents: number) => `CHF ${(cents / 100).toFixed(2)}`;
	const tokens = (n: number) => (n >= 1000 ? `${(Math.round(n / 100) / 10).toFixed(1)}k` : `${n}`);
</script>

{#if status?.delinquent}
	<!-- Payment failed: PAYG usage is paused until the card is updated. -->
	<a
		href="/settings/subscription"
		data-sveltekit-reload
		data-billing-state="payment_required"
		class="flex size-9 items-center justify-center rounded-lg text-destructive transition-colors hover:bg-destructive/10"
		aria-label="Payment required: update your payment method"
		title="Payment required: update your payment method"
	>
		<CreditCard class="size-5" />
	</a>
{/if}

{#if status && !status.exempt}
	<!-- Snapshot refreshes on open, mirroring the classic per-render recompute. -->
	<DropdownMenu.Root onOpenChange={(open) => open && void refresh()}>
		<DropdownMenu.Trigger
			class="flex size-9 items-center justify-center rounded-lg transition-colors hover:bg-accent/60"
			aria-label="Usage this period"
			title="Usage this period"
			data-testid="credit-indicator"
		>
			<span class="flex items-end gap-[3px]">
				{#each bars as bar, index (index)}
					<span class="h-3.5 w-[5px] rounded-sm {BAR_CLASS[bar]}"></span>
				{/each}
			</span>
		</DropdownMenu.Trigger>
		<DropdownMenu.Content side="right" align="end" class="w-64 p-4">
			<p class="text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
				Usage this period
			</p>

			<div class="mt-3 flex items-center justify-between">
				<span class="text-sm">Spent</span>
				<span class="text-sm font-semibold" data-testid="usage-spent">{chf(status.spentCents)}</span
				>
			</div>

			{#if capped}
				<div class="mt-1.5 h-2.5 w-full overflow-hidden rounded-full bg-secondary">
					<div class="h-full {progressClass}" style="width: {percentage}%"></div>
				</div>
				<p class="mt-1 text-xs text-muted-foreground">
					{status.trial ? `of ${chf(cap)} free trial allowance` : `of ${chf(cap)} monthly cap`}
				</p>
			{/if}

			{#if nearCap}
				<p class="mt-2 text-xs text-warning">
					{status.trial
						? "You've used most of your free trial allowance. Subscribe to Pay-as-you-go to keep going."
						: 'You have used most of your monthly cap. Usage stops at the cap. Raise it in Settings if you need more.'}
				</p>
			{/if}

			<div class="mt-3 flex items-center justify-between">
				<span class="text-sm">Tokens</span>
				<span class="text-sm font-semibold" data-testid="usage-tokens"
					>{tokens(status.tokensUsed)}</span
				>
			</div>

			<a
				href="/settings/subscription"
				data-sveltekit-reload
				class="mt-3 inline-block text-xs text-primary hover:underline"
			>
				Manage subscription
			</a>
		</DropdownMenu.Content>
	</DropdownMenu.Root>
{/if}
