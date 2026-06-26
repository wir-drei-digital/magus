import { describe, expect, it } from 'vitest';
import { mcpStatusBadge, mcpStatusToneClass } from './status';

describe('mcpStatusBadge', () => {
	it('reports disabled servers regardless of reachability/credential', () => {
		expect(
			mcpStatusBadge({ enabled: false, reachability: 'ok', credentialStatus: 'connected' })
		).toEqual({ label: 'Disabled', tone: 'muted' });
	});

	it('surfaces a credential error as Error', () => {
		expect(
			mcpStatusBadge({ enabled: true, reachability: 'ok', credentialStatus: 'error' })
		).toEqual({ label: 'Error', tone: 'error' });
	});

	it('surfaces a reachability error as Error', () => {
		expect(
			mcpStatusBadge({ enabled: true, reachability: 'error', credentialStatus: null })
		).toEqual({ label: 'Error', tone: 'error' });
	});

	it('surfaces needs_auth as a warning', () => {
		expect(
			mcpStatusBadge({ enabled: true, reachability: 'ok', credentialStatus: 'needs_auth' })
		).toEqual({ label: 'Needs auth', tone: 'warn' });
	});

	it('reports Connected when reachable and connected', () => {
		expect(
			mcpStatusBadge({ enabled: true, reachability: 'ok', credentialStatus: 'connected' })
		).toEqual({ label: 'Connected', tone: 'ok' });
	});

	it('treats a reachable server with no credential as Connected', () => {
		expect(mcpStatusBadge({ enabled: true, reachability: 'ok', credentialStatus: null })).toEqual({
			label: 'Connected',
			tone: 'ok'
		});
	});

	it('reports Disconnected for a disconnected credential on an unknown server', () => {
		expect(
			mcpStatusBadge({ enabled: true, reachability: 'unknown', credentialStatus: 'disconnected' })
		).toEqual({ label: 'Disconnected', tone: 'muted' });
	});

	it('falls back to Unknown when nothing is known', () => {
		expect(
			mcpStatusBadge({ enabled: true, reachability: 'unknown', credentialStatus: null })
		).toEqual({ label: 'Unknown', tone: 'muted' });
	});
});

describe('mcpStatusToneClass', () => {
	it('maps each tone to a distinct class set', () => {
		const tones = ['ok', 'warn', 'error', 'muted'] as const;
		const classes = tones.map(mcpStatusToneClass);
		expect(new Set(classes).size).toBe(tones.length);
		expect(mcpStatusToneClass('error')).toContain('destructive');
	});
});
