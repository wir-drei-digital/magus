import { getSocket } from './socket';

/**
 * Joins `workspace:<id>` and invokes the callback on every `file.*` push
 * (workspace-scoped file events from other members). Returns a cleanup
 * function; safe to call when the socket is unavailable.
 */
export async function joinWorkspaceFiles(
	workspaceId: string,
	onFileEvent: () => void
): Promise<() => void> {
	const socket = await getSocket();
	if (!socket) return () => {};

	const channel = socket.channel(`workspace:${workspaceId}`);

	channel.onMessage = (event, payload) => {
		if (event.startsWith('file.')) onFileEvent();
		return payload;
	};

	channel.join();
	return () => {
		channel.leave();
	};
}
