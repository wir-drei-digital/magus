import type { McpCredentialStatus, McpReachability } from '$lib/ash/api';

/** Visual tone for a status badge, mapped to Tailwind utility classes by the UI. */
export type McpStatusTone = 'ok' | 'warn' | 'error' | 'muted';

export type McpStatusBadge = {
	label: string;
	tone: McpStatusTone;
};

/**
 * Combine a server's reachability with its per-user credential status into a
 * single badge. Pure (no DOM, no network) so it can be unit-tested.
 *
 * Precedence:
 *  - disabled server wins (nothing else matters)
 *  - an explicit credential error or a reachability error surfaces as `error`
 *  - `needs_auth` (credential present but not authorized) surfaces as `warn`
 *  - reachable + connected → `ok`
 *  - otherwise fall back to the credential status, then reachability
 */
export function mcpStatusBadge(args: {
	enabled: boolean;
	reachability: McpReachability;
	credentialStatus: McpCredentialStatus | null;
}): McpStatusBadge {
	const { enabled, reachability, credentialStatus } = args;

	if (!enabled) return { label: 'Disabled', tone: 'muted' };

	if (credentialStatus === 'error' || reachability === 'error') {
		return { label: 'Error', tone: 'error' };
	}

	if (credentialStatus === 'needs_auth') {
		return { label: 'Needs auth', tone: 'warn' };
	}

	if (reachability === 'ok' && (credentialStatus === 'connected' || credentialStatus === null)) {
		return { label: 'Connected', tone: 'ok' };
	}

	if (credentialStatus === 'disconnected') {
		return { label: 'Disconnected', tone: 'muted' };
	}

	if (reachability === 'ok') return { label: 'Reachable', tone: 'ok' };

	return { label: 'Unknown', tone: 'muted' };
}

/** Tailwind classes for each tone (kept here so the mapping is testable + reused). */
export function mcpStatusToneClass(tone: McpStatusTone): string {
	switch (tone) {
		case 'ok':
			return 'bg-success/15 text-success';
		case 'warn':
			return 'bg-warning/15 text-warning';
		case 'error':
			return 'bg-destructive/15 text-destructive';
		case 'muted':
		default:
			return 'bg-secondary text-muted-foreground';
	}
}
