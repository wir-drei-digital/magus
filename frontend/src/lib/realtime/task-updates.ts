import { getSocket } from './socket';

export type TaskUpdate = {
	/** The PubSub event: `task.created` | `task.updated` | `task.changed`. */
	event: string;
	/** The affected task's id (a hint: the caller refetches its list). */
	taskId: string | null;
};

/**
 * Subscribes to a topic that relays `task.*` events and invokes the callback
 * per event. The backend channel re-pushes a JSON-safe `%{task_id}` hint; the
 * caller typically just refetches its task list (avoids stale-merge bugs).
 * Returns a cleanup function that leaves the channel.
 */
async function joinTaskTopic(
	topic: string,
	onEvent: (update: TaskUpdate) => void
): Promise<() => void> {
	const socket = await getSocket();
	if (!socket) return () => {};

	const channel = socket.channel(topic);

	channel.onMessage = (event, payload) => {
		if (event.startsWith('task.')) {
			const data = (payload ?? {}) as Record<string, unknown>;
			onEvent({
				event,
				taskId: typeof data.task_id === 'string' ? data.task_id : null
			});
		}
		return payload;
	};

	channel.join();
	return () => {
		channel.leave();
	};
}

/**
 * Joins `plan_tasks:<brainPageId>`: live task events for one plan board, so
 * other clients' (agents') claims / status changes / creates appear live.
 */
export function joinPlanTasks(
	brainPageId: string,
	onEvent: (update: TaskUpdate) => void
): Promise<() => void> {
	return joinTaskTopic(`plan_tasks:${brainPageId}`, onEvent);
}

/**
 * Joins `brain_tasks:<brainId>`: live task events across a whole brain, for the
 * brain overview's in-flight / rollup / activity to update live.
 */
export function joinBrainTasks(
	brainId: string,
	onEvent: (update: TaskUpdate) => void
): Promise<() => void> {
	return joinTaskTopic(`brain_tasks:${brainId}`, onEvent);
}
