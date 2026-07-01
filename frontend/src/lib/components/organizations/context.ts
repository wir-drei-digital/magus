import { getContext, setContext } from 'svelte';
import type { OrganizationDetail, OrgMemberEntry } from '$lib/ash/api';

/**
 * Route-scoped state shared by the settings/organization layout and its
 * members/usage/billing pages. The layout resolves the signed-in user's
 * membership once (org + role), loads the roster, and exposes `reload` so a page
 * mutation (invite, role change, remove) refreshes without re-resolving the org.
 *
 * `isOwner` reflects the membership role only — it hides owner-only controls in
 * the UI. It is NOT the authorization boundary: the server enforces every
 * mutation via the organization policies.
 */
export type OrgAdminState = {
	org: OrganizationDetail | null;
	members: OrgMemberEntry[];
	loading: boolean;
	error: string | null;
	/** The signed-in user is the owner of this organization. */
	isOwner: boolean;
	/** The signed-in user's id (to flag their own roster row). */
	currentUserId: string | null;
	/** Refetch the members roster (and recompute owner-derived flags). */
	reload: () => Promise<void>;
};

const KEY = Symbol('org-admin');

export function setOrgAdmin(state: OrgAdminState): void {
	setContext(KEY, state);
}

export function getOrgAdmin(): OrgAdminState {
	return getContext(KEY) as OrgAdminState;
}
