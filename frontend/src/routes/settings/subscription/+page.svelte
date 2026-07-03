<script lang="ts">
	import { onMount } from 'svelte';
	import { AlertCircle, CreditCard, ExternalLink } from '@lucide/svelte';
	import {
		Section as SettingsSection,
		Button,
		ToggleSwitch,
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

	// Editable spend-cap controls, seeded from the overview. `capCents` is the
	// explicit monthly cap; null means "use the platform default" (a null cap is
	// not unlimited — that's what the no-cap toggle is for).
	let noSpendCap = $state(false);
	let capCents = $state<number | null>(null);
	let capInput = $state(''); // custom-amount field, kept in sync with capCents
	let seededFor: string | null = null;
	$effect(() => {
		const o = overview;
		if (o && seededFor !== o.status + o.monthlySpendCapCents) {
			seededFor = o.status + o.monthlySpendCapCents;
			noSpendCap = o.noSpendCap;
			capCents = o.monthlySpendCapCents;
			capInput = o.monthlySpendCapCents != null ? chfString(o.monthlySpendCapCents) : '';
		}
	});

	// Slider, preset chips and the custom input all edit the same `capCents`.
	const CAP_PRESETS_CENTS = [500, 1000, 2000, 5000];
	const SLIDER_MAX_CHF = 50;

	const defaultCapCents = $derived(overview?.defaultCapCents ?? overview?.capCents ?? null);

	// Slider position in whole CHF: the set cap, else the default; clamped to range.
	const sliderChf = $derived(
		Math.min(SLIDER_MAX_CHF, Math.max(0, Math.round((capCents ?? defaultCapCents ?? 0) / 100)))
	);

	function chfString(cents: number): string {
		const chf = cents / 100;
		return Number.isInteger(chf) ? String(chf) : chf.toFixed(2);
	}

	function setCap(cents: number | null) {
		capCents = cents;
		capInput = cents != null ? chfString(cents) : '';
	}

	function onSliderInput(event: Event) {
		setCap(Math.round(Number((event.currentTarget as HTMLInputElement).value)) * 100);
	}

	function onCustomInput(event: Event) {
		capInput = (event.currentTarget as HTMLInputElement).value;
		const chf = Number(capInput);
		capCents =
			capInput.trim() === '' || !Number.isFinite(chf) || chf < 0 ? null : Math.round(chf * 100);
	}

	function chipClass(active: boolean): string {
		return (
			'rounded-md border px-2.5 py-1 text-xs font-medium transition-colors ' +
			(active
				? 'border-primary bg-primary text-primary-foreground'
				: 'border-input text-muted-foreground hover:bg-muted hover:text-foreground')
		);
	}

	// Save is gated on an actual change to the spend preferences.
	const prefsDirty = $derived(
		!!overview &&
			(noSpendCap !== overview.noSpendCap ||
				(!noSpendCap && capCents !== overview.monthlySpendCapCents))
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
		const result = await setBillingPreferences({
			monthlySpendCapCents: noSpendCap ? null : capCents,
			noSpendCap
		});
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
				description="Pay-as-you-go usage is billed at cost. Set a monthly cap, or turn the cap off and pay exactly what you use."
			>
				{#if !noSpendCap}
					<div class="flex items-baseline justify-between gap-4">
						<span class="text-sm font-medium">Monthly spend cap</span>
						<span class="text-lg font-semibold" data-testid="billing-cap-readout">
							{#if capCents != null}
								{formatCents(capCents)}
								<span class="text-sm font-normal text-muted-foreground">/ month</span>
							{:else}
								Default · {formatCents(defaultCapCents)}
							{/if}
						</span>
					</div>

					<input
						type="range"
						min="0"
						max={SLIDER_MAX_CHF}
						step="1"
						value={sliderChf}
						oninput={onSliderInput}
						aria-label="Monthly spend cap"
						class="mt-3 w-full accent-primary"
						data-testid="billing-cap-slider"
					/>
					<div class="flex justify-between px-1 text-xs text-muted-foreground">
						<span>CHF 0</span>
						<span>CHF {SLIDER_MAX_CHF / 2}</span>
						<span>CHF {SLIDER_MAX_CHF}+</span>
					</div>

					<div class="mt-3 flex flex-wrap items-center gap-2">
						{#each CAP_PRESETS_CENTS as cents (cents)}
							<button
								type="button"
								onclick={() => setCap(cents)}
								class={chipClass(capCents === cents)}
								data-testid="billing-cap-preset-{cents}"
							>
								CHF {cents / 100}
							</button>
						{/each}
						<button
							type="button"
							onclick={() => setCap(null)}
							class={chipClass(capCents === null)}
							data-testid="billing-cap-default"
						>
							Default
						</button>
						<input
							type="number"
							min="0"
							step="0.5"
							value={capInput}
							oninput={onCustomInput}
							placeholder="Custom"
							aria-label="Custom monthly cap in CHF"
							class="{CONTROL_CLASS} ml-auto max-w-24"
							data-testid="billing-cap-input"
						/>
					</div>

					<p class="mt-2 text-xs text-muted-foreground">
						For a sense of scale: a typical chat turn costs around 1 Rappen. Light use stays under
						CHF 5/month; heavy agent use can reach CHF 20+. Usage stops at the cap.
					</p>
				{/if}

				<div
					class="mt-4 flex items-center justify-between gap-4 border-t border-border pt-4 text-sm"
				>
					<span>No spend cap: pay exactly what you use</span>
					<ToggleSwitch
						checked={noSpendCap}
						onchange={(next) => (noSpendCap = next)}
						label="No spend cap"
						testid="billing-no-cap"
					/>
				</div>
				{#if noSpendCap}
					<p class="mt-2 text-sm text-muted-foreground">
						Your usage is never blocked. Whatever you use is billed with your monthly invoice.
					</p>
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
