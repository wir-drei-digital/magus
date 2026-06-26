<script lang="ts">
	import { onMount } from 'svelte';
	import { AlertCircle, CreditCard, ExternalLink } from '@lucide/svelte';
	import {
		Section as SettingsSection,
		Button,
		ToggleSwitch,
		Field,
		CONTROL_CLASS
	} from '$lib/components/crud';
	import {
		billingOverview,
		openBillingPortal,
		setBillingPreferences,
		startBaseCheckout,
		type BillingOverview
	} from '$lib/ash/api';
	import { formatCents, formatTokens } from '$lib/billing/format';

	let overview = $state<BillingOverview | null>(null);
	let loading = $state(true);
	let busy = $state(false);
	let saveError = $state<string | null>(null);

	// Editable spend-cap controls, seeded from the overview.
	let noSpendCap = $state(false);
	let capChf = $state('');
	let seededFor: string | null = null;
	$effect(() => {
		const o = overview;
		if (o && seededFor !== o.status + o.monthlySpendCapCents) {
			seededFor = o.status + o.monthlySpendCapCents;
			noSpendCap = o.noSpendCap;
			capChf = o.monthlySpendCapCents != null ? (o.monthlySpendCapCents / 100).toFixed(2) : '';
		}
	});

	// Save is gated on an actual change to the spend preferences.
	const capBaseline = $derived(
		overview?.monthlySpendCapCents != null ? (overview.monthlySpendCapCents / 100).toFixed(2) : ''
	);
	const prefsDirty = $derived(
		!!overview && (noSpendCap !== overview.noSpendCap || (!noSpendCap && capChf !== capBaseline))
	);

	// A failed/past-due payment that needs the user's attention.
	const paymentIssue = $derived(
		overview != null &&
			(overview.delinquent ||
				overview.status === 'past_due' ||
				overview.lastPaymentStatus === 'failed')
	);

	const returnTo = $derived(typeof window !== 'undefined' ? window.location.href : undefined);

	onMount(() => {
		void billingOverview().then((result) => {
			if (result.success) overview = result.data;
			loading = false;
		});
	});

	async function savePreferences() {
		busy = true;
		saveError = null;
		const cents = noSpendCap ? null : Math.round((Number(capChf) || 0) * 100);
		const result = await setBillingPreferences({ monthlySpendCapCents: cents, noSpendCap });
		busy = false;
		if (result.success) overview = result.data;
		else saveError = result.errors[0]?.message ?? 'Could not save spend preferences';
	}

	async function manageBilling() {
		busy = true;
		const ok = await openBillingPortal(returnTo);
		if (!ok) {
			busy = false;
			saveError = 'Could not open the billing portal.';
		}
	}

	async function upgrade() {
		busy = true;
		const ok = await startBaseCheckout(returnTo);
		if (!ok) {
			busy = false;
			saveError = 'Could not start checkout.';
		}
	}

	function statusLabel(status: string): string {
		return status.replace(/_/g, ' ');
	}
</script>

{#if loading}
	<div
		class="h-40 animate-pulse rounded-xl bg-muted/60"
		data-testid="settings-subscription-loading"
	></div>
{:else if !overview}
	<p class="text-sm text-muted-foreground">Billing is currently unavailable.</p>
{:else}
	<div class="space-y-6" data-testid="settings-subscription">
		{#if overview.billingEdition && paymentIssue}
			<div
				class="flex items-start gap-2 rounded-lg border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive"
				data-testid="billing-payment-issue"
			>
				<AlertCircle class="mt-0.5 size-4 shrink-0" />
				<div>
					<p class="font-medium">There's a problem with your payment.</p>
					<p class="text-xs">Update your payment method to keep using paid features.</p>
				</div>
			</div>
		{/if}

		<SettingsSection title="Plan" description="Your current subscription.">
			<div class="flex items-center justify-between gap-4">
				<div>
					<p class="font-medium" data-testid="billing-plan">
						{overview.planName ?? overview.planKey ?? 'No plan'}
					</p>
					<p class="text-xs text-muted-foreground capitalize">
						{statusLabel(overview.status)}{#if overview.currentPeriodEnd}
							· renews {new Date(overview.currentPeriodEnd).toLocaleDateString()}{/if}
					</p>
				</div>
				{#if overview.billingEdition}
					<div class="flex shrink-0 gap-2">
						{#if !overview.isPayg && !overview.exempt}
							<Button onclick={() => void upgrade()} disabled={busy} data-testid="billing-upgrade">
								<CreditCard class="size-4" /> Upgrade
							</Button>
						{/if}
						<Button
							variant="outline"
							onclick={() => void manageBilling()}
							disabled={busy}
							data-testid="billing-portal"
						>
							<ExternalLink class="size-4" /> Manage billing
						</Button>
					</div>
				{/if}
			</div>
		</SettingsSection>

		<SettingsSection title="Usage this period" description="Pay-as-you-go spend this period.">
			<dl class="grid grid-cols-2 gap-3 text-sm">
				<div>
					<dt class="text-xs text-muted-foreground">Spent</dt>
					<dd class="font-medium" data-testid="billing-spent">
						{formatCents(overview.spentCents)}{#if overview.capCents != null}
							<span class="text-xs text-muted-foreground">
								/ {formatCents(overview.capCents)}</span
							>{/if}
					</dd>
				</div>
				<div>
					<dt class="text-xs text-muted-foreground">Tokens</dt>
					<dd class="font-medium">{formatTokens(overview.tokensUsed)}</dd>
				</div>
			</dl>
		</SettingsSection>

		{#if !overview.exempt}
			<SettingsSection
				title="Spending controls"
				description="Cap your monthly pay-as-you-go spend."
			>
				<div class="flex items-center justify-between gap-4 text-sm">
					<span>No spending cap (uncapped pay-as-you-go)</span>
					<ToggleSwitch
						checked={noSpendCap}
						onchange={(next) => (noSpendCap = next)}
						label="No spending cap"
						testid="billing-no-cap"
					/>
				</div>

				{#if !noSpendCap}
					<div class="mt-3 max-w-xs">
						<Field label="Monthly cap (CHF)">
							<input
								type="number"
								min="0"
								step="1"
								bind:value={capChf}
								class={CONTROL_CLASS}
								data-testid="billing-cap-input"
							/>
						</Field>
					</div>
				{/if}

				{#if saveError}
					<p class="mt-2 text-xs text-destructive">{saveError}</p>
				{/if}

				<div class="mt-4">
					<Button
						onclick={() => void savePreferences()}
						disabled={busy || !prefsDirty}
						data-testid="billing-save"
					>
						Save
					</Button>
				</div>
			</SettingsSection>
		{/if}
	</div>
{/if}
