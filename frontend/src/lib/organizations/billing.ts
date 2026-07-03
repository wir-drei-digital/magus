/**
 * Pure, DOM-free helpers for the organization Billing tab. Kept separate from
 * the Svelte view so they stay unit-testable in the node vitest environment and
 * carry no dependency on the generated RPC client.
 *
 * The CTA a Billing tab shows is fully determined by three server flags, so it
 * lives here as `billingAction` rather than being re-derived inline in the view.
 */

/** The minimal overview shape these helpers read; the real overview is a superset. */
export type BillingOverviewLike = {
	billingStatus: string;
	seatCount: number;
	billingSetUp: boolean;
	billingEdition: boolean;
};

/**
 * The single call to action the Billing tab renders:
 *  - `unavailable`: no commercial billing edition (open-core self-host), no Stripe.
 *  - `setup`: edition present, but the org has not started checkout yet.
 *  - `manage`: billing is set up; open the Stripe portal.
 */
export type BillingAction = { kind: 'unavailable' } | { kind: 'setup' } | { kind: 'manage' };

const STATUS_LABELS: Record<string, string> = {
	active: 'Active',
	canceled: 'Canceled',
	incomplete: 'Incomplete',
	past_due: 'Past due',
	trialing: 'Trialing'
};

/**
 * A friendly label for a Stripe subscription status. Known statuses map to a
 * curated label; anything unexpected is de-snaked and capitalized so a new
 * server status still reads cleanly instead of leaking a raw token.
 */
export function billingStatusLabel(status: string): string {
	const known = STATUS_LABELS[status];
	if (known) return known;
	const spaced = status.replace(/_/g, ' ').trim();
	if (spaced === '') return 'Unknown';
	return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

/**
 * Derive the Billing tab's call to action from the overview flags. The edition
 * gate wins over everything: without it there is no Stripe surface to act on.
 */
export function billingAction(overview: BillingOverviewLike): BillingAction {
	if (!overview.billingEdition) return { kind: 'unavailable' };
	if (!overview.billingSetUp) return { kind: 'setup' };
	return { kind: 'manage' };
}

/**
 * The status headline for the Plan card. `billing_status` defaults to `active`
 * on the server before any checkout has happened (the column only gates
 * past_due/canceled), so an org without a Stripe subscription must not read
 * "Active" next to a "Set up billing" CTA - it reads "Not set up" until
 * checkout completes.
 */
export function billingStatusDisplay(overview: BillingOverviewLike): string {
	if (!overview.billingSetUp) return 'Not set up';
	return billingStatusLabel(overview.billingStatus);
}
