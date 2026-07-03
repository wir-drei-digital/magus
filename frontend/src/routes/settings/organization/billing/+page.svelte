<script lang="ts">
	import { CreditCard, ExternalLink } from '@lucide/svelte';
	import { page } from '$app/state';
	import { Button, Section } from '$lib/components/crud';
	import { getOrgAdmin } from '$lib/components/organizations/context';
	import {
		openOrgBillingPortal,
		orgBillingOverview,
		startOrgCheckout,
		type OrgBillingOverview
	} from '$lib/ash/api';
	import { billingAction, billingStatusDisplay } from '$lib/organizations/billing';
	import { seatLabel } from '$lib/organizations/usage';

	const ctx = getOrgAdmin();

	let overview = $state<OrgBillingOverview | null>(null);
	let loaded = $state(false);
	let busy = $state(false);
	let actionError = $state<string | null>(null);

	// Load once the layout has resolved the org id. This is an owner-only surface;
	// the layout hides the Billing tab for members, and the server enforces it.
	let loadedFor: string | null = null;
	$effect(() => {
		const id = ctx.org?.id;
		if (!id || loadedFor === id) return;
		loadedFor = id;
		void orgBillingOverview(id).then((result) => {
			if (result.success) overview = result.data;
			loaded = true;
		});
	});

	const action = $derived(overview ? billingAction(overview) : null);

	// Track the live URL so Stripe returns the user to whatever org/billing view
	// they launched checkout from, even after client-side navigation. `page.url`
	// is reactive (unlike a one-shot `window.location.href` read).
	const returnTo = $derived(page.url.href);

	async function setup() {
		if (!ctx.org) return;
		busy = true;
		actionError = null;
		const ok = await startOrgCheckout(ctx.org.id, returnTo);
		if (!ok) {
			busy = false;
			actionError = 'Could not start checkout.';
		}
	}

	async function manage() {
		if (!ctx.org) return;
		busy = true;
		actionError = null;
		const ok = await openOrgBillingPortal(ctx.org.id, returnTo);
		if (!ok) {
			busy = false;
			actionError = 'Could not open the billing portal.';
		}
	}
</script>

{#if !ctx.isOwner}
	<p class="text-sm text-muted-foreground" data-testid="org-billing-owners-only">
		Only the organization owner can manage billing.
	</p>
{:else if !loaded}
	<div class="h-40 animate-pulse rounded-xl bg-muted/60" data-testid="org-billing-loading"></div>
{:else if !overview}
	<p class="text-sm text-muted-foreground">Billing is currently unavailable.</p>
{:else if !overview.billingEdition}
	<Section
		title="Billing"
		description="Centralized billing for your organization."
		testid="org-billing"
	>
		<p class="text-sm text-muted-foreground" data-testid="org-billing-unavailable">
			Organization billing is available in the cloud edition.
		</p>
	</Section>
{:else}
	<div class="flex flex-col gap-5" data-testid="org-billing">
		<Section title="Plan" description="Your organization's billing subscription.">
			<div class="flex items-center justify-between gap-4">
				<div>
					<p class="font-medium" data-testid="org-billing-status">
						{billingStatusDisplay(overview)}
					</p>
					<p class="text-xs text-muted-foreground">
						{seatLabel(overview.seatCount)}{#if overview.currentPeriodEnd}
							· renews {new Date(overview.currentPeriodEnd).toLocaleDateString()}{/if}
					</p>
				</div>

				<div class="shrink-0">
					{#if action?.kind === 'setup'}
						<Button onclick={() => void setup()} disabled={busy} data-testid="org-billing-setup">
							<CreditCard class="size-4" /> Set up billing
						</Button>
					{:else if action?.kind === 'manage'}
						<Button
							variant="outline"
							onclick={() => void manage()}
							disabled={busy}
							data-testid="org-billing-portal"
						>
							<ExternalLink class="size-4" /> Manage payment
						</Button>
					{/if}
				</div>
			</div>

			{#if actionError}
				<p class="mt-3 text-xs text-destructive" data-testid="org-billing-error">{actionError}</p>
			{/if}
		</Section>
	</div>
{/if}
