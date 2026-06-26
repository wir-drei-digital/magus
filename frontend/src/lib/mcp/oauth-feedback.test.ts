import { describe, expect, it } from 'vitest';
import { mcpOAuthFeedback, type McpOAuthErrorCode } from './oauth-feedback';

const ERROR_CODES: McpOAuthErrorCode[] = [
	'client_id_required',
	'discovery_failed',
	'not_oauth',
	'invalid_state',
	'denied',
	'exchange_failed',
	'server_unavailable'
];

describe('mcpOAuthFeedback', () => {
	it('returns null when neither param is present', () => {
		expect(mcpOAuthFeedback(null, null)).toBeNull();
	});

	it('reports success for mcp_oauth=connected', () => {
		const feedback = mcpOAuthFeedback('connected', null);
		expect(feedback?.tone).toBe('ok');
		expect(feedback?.message).not.toBe('');
	});

	it('ignores an unrecognized success value', () => {
		expect(mcpOAuthFeedback('something_else', null)).toBeNull();
	});

	it('maps every known error code to a non-empty error message', () => {
		for (const code of ERROR_CODES) {
			const feedback = mcpOAuthFeedback(null, code);
			expect(feedback?.tone).toBe('error');
			expect(feedback?.message.length).toBeGreaterThan(0);
		}
	});

	it('handles an unknown error code gracefully', () => {
		const feedback = mcpOAuthFeedback(null, 'totally_unknown_code');
		expect(feedback?.tone).toBe('error');
		expect(feedback?.message.length).toBeGreaterThan(0);
	});

	it('prefers the error param when both are somehow present', () => {
		const feedback = mcpOAuthFeedback('connected', 'denied');
		expect(feedback?.tone).toBe('error');
	});
});
