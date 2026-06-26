import { getContext, setContext } from 'svelte';
import type { WorkspaceDetail, WorkspaceMemberEntry } from '$lib/ash/api';

/**
 * Route-scoped state shared by the workspace [slug] layout and its
 * settings/members/usage pages: the layout loads the workspace + members once,
 * enforces the admin gate, and exposes reload helpers so a page mutation
 * (rename, invite, role change) refreshes without a redundant slug fetch.
 */
export type WorkspaceAdminState = {
	slug: string;
	workspace: WorkspaceDetail | null;
	members: WorkspaceMemberEntry[];
	loading: boolean;
	error: string | null;
	/** The signed-in user is an active admin of this workspace. */
	isAdmin: boolean;
	/** The signed-in user's own member row id (to disable self-actions). */
	currentMemberId: string | null;
	reloadWorkspace: () => Promise<void>;
	reloadMembers: () => Promise<void>;
};

const KEY = Symbol('workspace-admin');

export function setWorkspaceAdmin(state: WorkspaceAdminState): void {
	setContext(KEY, state);
}

export function getWorkspaceAdmin(): WorkspaceAdminState {
	return getContext(KEY) as WorkspaceAdminState;
}
