import { untrack } from 'svelte';
import { currentUser, selectWorkspace, updateUiPreferences, type CurrentUser } from '$lib/ash/api';
import { clearShellCache, readShellCache, writeShellCache } from '$lib/shell-cache';

export type SessionStatus = 'loading' | 'authenticated' | 'unauthenticated' | 'error';

const USER_CACHE_KEY = 'session-user';

class Session {
	user = $state<CurrentUser | null>(null);
	status = $state<SessionStatus>('loading');

	/** Hard session expiry (socket token refresh got a 401 mid-session). */
	markExpired(): void {
		this.status = 'unauthenticated';
		this.user = null;
		clearShellCache();
	}

	async load(): Promise<void> {
		// Boot from the last known user so the shell (and the dependent nav
		// loads) renders immediately; the fetch below verifies in background.
		// untrack: load() runs inside the layout's boot $effect — a tracked
		// read of this.user would make that effect re-run on every user
		// replacement, looping current_user fetches forever.
		const cached =
			untrack(() => this.user) === null ? readShellCache<CurrentUser>(USER_CACHE_KEY) : null;
		if (cached) {
			this.user = cached;
			this.status = 'authenticated';
		}

		const result = await currentUser();

		if (result.success) {
			this.user = result.data;
			this.status = 'authenticated';
			writeShellCache(USER_CACHE_KEY, result.data);
		} else if (result.errors.some((error) => error.type === 'unauthenticated')) {
			this.markExpired();
		} else if (!cached) {
			// With a cached user a transient network error keeps the stale
			// shell usable instead of flipping to the error card.
			this.status = 'error';
		}
	}

	/**
	 * Persists the workspace selection. Replacing `this.user` changes the
	 * layout's session key (user id | workspace id), which re-triggers the
	 * shell load + notification reconnect automatically.
	 */
	async selectWorkspace(workspaceId: string | null): Promise<boolean> {
		if (!this.user) return false;
		const result = await selectWorkspace(this.user.id, workspaceId);
		if (!result.success) return false;
		this.user = result.data;
		writeShellCache(USER_CACHE_KEY, result.data);
		return true;
	}

	/** Optimistic single-key write into ui_preferences, server-reconciled. */
	async setUiPreference(key: string, value: unknown): Promise<boolean> {
		if (!this.user) return false;

		const preferences = { ...(this.user.uiPreferences ?? {}), [key]: value };
		const previous = this.user;
		this.user = { ...previous, uiPreferences: preferences };

		const result = await updateUiPreferences(previous.id, preferences);
		if (result.success) {
			this.user = result.data;
			writeShellCache(USER_CACHE_KEY, result.data);
			return true;
		}

		this.user = previous;
		return false;
	}
}

export const session = new Session();
