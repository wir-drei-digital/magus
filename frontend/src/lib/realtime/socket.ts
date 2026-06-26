import { Socket } from 'phoenix';
import { session } from '$lib/stores/session.svelte';

/**
 * Singleton Phoenix socket for the workbench.
 *
 * Auth is token-based (GET /rpc/socket-token, session-authenticated), so the
 * same flow works for the browser SPA today and Capacitor/CLI clients later.
 * The token is refreshed on socket errors so long-lived sessions survive the
 * 24h token TTL across reconnects. A 401 on refresh means the SESSION died:
 * we stop reconnecting with the dead token and flip the session store to
 * unauthenticated so the shell shows the sign-in state.
 */

let socket: Socket | null = null;
let token: string | null = null;

type TokenResult = { status: 'ok'; token: string } | { status: 'unauthorized' | 'error' };

async function fetchToken(): Promise<TokenResult> {
	try {
		const response = await fetch('/rpc/socket-token', {
			credentials: 'same-origin',
			headers: { accept: 'application/json' }
		});
		if (response.status === 401) return { status: 'unauthorized' };
		if (!response.ok) return { status: 'error' };
		const body = (await response.json()) as { token?: string };
		return body.token ? { status: 'ok', token: body.token } : { status: 'error' };
	} catch {
		// Network failure — transient; keep retrying with the current token.
		return { status: 'error' };
	}
}

export async function getSocket(): Promise<Socket | null> {
	if (socket) return socket;

	const initial = await fetchToken();
	if (initial.status === 'unauthorized') {
		session.markExpired();
		return null;
	}
	if (initial.status !== 'ok') return null;
	token = initial.token;

	socket = new Socket('/socket', {
		// Evaluated on every (re)connect attempt; onError refreshes the token.
		params: () => ({ token })
	});

	socket.onError(() => {
		void fetchToken().then((result) => {
			if (result.status === 'ok') {
				token = result.token;
			} else if (result.status === 'unauthorized') {
				// Session expired: stop hammering the socket with a dead token.
				disconnectSocket();
				session.markExpired();
			}
		});
	});

	socket.connect();
	return socket;
}

export function disconnectSocket(): void {
	socket?.disconnect();
	socket = null;
	token = null;
}
