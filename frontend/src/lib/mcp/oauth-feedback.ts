/**
 * Pure mapping from the OAuth-return query params to a user-facing feedback
 * message. The Task 4 controller redirects back to the settings page with
 * exactly one param:
 *   - `mcp_oauth=connected`        — success
 *   - `mcp_oauth_error=<code>`     — failure, `<code>` ∈ the fixed set below
 *
 * Pure (no DOM, no network) so it is unit-testable; the redirect/flow itself is
 * e2e/manual. No secret material is ever present in these params.
 */

/** The fixed set of error codes the OAuth controller may return. */
export type McpOAuthErrorCode =
	| 'client_id_required'
	| 'discovery_failed'
	| 'not_oauth'
	| 'invalid_state'
	| 'denied'
	| 'exchange_failed'
	| 'server_unavailable';

export type McpOAuthFeedback = {
	tone: 'ok' | 'error';
	message: string;
};

const ERROR_MESSAGES: Record<McpOAuthErrorCode, string> = {
	client_id_required:
		'This server needs a client ID before connecting. Add one in the server settings, then try again.',
	discovery_failed:
		"Couldn't read the server's OAuth configuration. Check the URL and that the server supports OAuth.",
	not_oauth: 'This server does not advertise OAuth. Use a different authentication method.',
	invalid_state:
		'The connection could not be verified (the request expired or was tampered with). Please try connecting again.',
	denied: 'You declined the authorization request. The server was not connected.',
	exchange_failed:
		"Couldn't complete the token exchange with the server. Please try connecting again.",
	server_unavailable:
		'The server was unreachable during the connection. Check that it is online and try again.'
};

const SUCCESS_MESSAGE = 'Connected successfully.';

/**
 * Turn the raw query params into feedback, or `null` when neither param is
 * present. Unknown error codes are handled gracefully with a generic message.
 *
 * @param success the raw `mcp_oauth` value (e.g. `'connected'`), or null
 * @param errorCode the raw `mcp_oauth_error` value, or null
 */
export function mcpOAuthFeedback(
	success: string | null,
	errorCode: string | null
): McpOAuthFeedback | null {
	if (errorCode) {
		const message =
			ERROR_MESSAGES[errorCode as McpOAuthErrorCode] ??
			'Could not connect to the server. Please try again.';
		return { tone: 'error', message };
	}

	if (success === 'connected') {
		return { tone: 'ok', message: SUCCESS_MESSAGE };
	}

	return null;
}
