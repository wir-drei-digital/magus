import { describe, it, expect, vi, beforeEach } from 'vitest';

/**
 * Coverage for the task live-updates seam: joining the right channel topic per
 * scope (plan board / brain overview), parsing the `task.*` hint into the
 * callback, ignoring unrelated events, and leaving the channel on cleanup.
 *
 * The Phoenix socket is mocked (the only I/O), so this runs under the node
 * vitest env with no real WS. It mirrors how the board + overview consume the
 * module: an incoming `task.*` event drives a store refresh via the callback.
 */

// ─── socket mock ─────────────────────────────────────────────────────────────
type Listener = (event: string, payload: unknown) => unknown;

class FakeChannel {
	onMessage: Listener = (_e, p) => p;
	joined = false;
	left = false;
	constructor(public topic: string) {}
	join() {
		this.joined = true;
		return this;
	}
	leave() {
		this.left = true;
	}
	/** Test helper: simulate the server pushing an event onto this channel. */
	emit(event: string, payload: unknown) {
		this.onMessage(event, payload);
	}
}

const channels: FakeChannel[] = [];
const fakeSocket = {
	channel(topic: string) {
		const ch = new FakeChannel(topic);
		channels.push(ch);
		return ch;
	}
};

let socketResult: typeof fakeSocket | null = fakeSocket;
const getSocket = vi.fn(async () => socketResult);

vi.mock('./socket', () => ({
	getSocket: () => getSocket()
}));

import { joinPlanTasks, joinBrainTasks, type TaskUpdate } from './task-updates';

beforeEach(() => {
	channels.length = 0;
	socketResult = fakeSocket;
	getSocket.mockClear();
});

describe('joinPlanTasks', () => {
	it('joins the plan-scoped channel topic', async () => {
		await joinPlanTasks('page-1', () => {});
		expect(channels).toHaveLength(1);
		expect(channels[0].topic).toBe('plan_tasks:page-1');
		expect(channels[0].joined).toBe(true);
	});

	it('parses task.* events into the callback (task_id hint)', async () => {
		const updates: TaskUpdate[] = [];
		await joinPlanTasks('page-1', (u) => updates.push(u));
		const ch = channels[0];

		ch.emit('task.created', { task_id: 'task-a' });
		ch.emit('task.updated', { task_id: 'task-b' });
		ch.emit('task.changed', {}); // no id → null

		expect(updates).toEqual([
			{ event: 'task.created', taskId: 'task-a' },
			{ event: 'task.updated', taskId: 'task-b' },
			{ event: 'task.changed', taskId: null }
		]);
	});

	it('ignores non-task events (e.g. phx_reply)', async () => {
		const updates: TaskUpdate[] = [];
		await joinPlanTasks('page-1', (u) => updates.push(u));
		const ch = channels[0];

		ch.emit('phx_reply', { status: 'ok' });
		ch.emit('presence_state', {});

		expect(updates).toHaveLength(0);
	});

	it('returns the original payload from onMessage (preserves the pipeline)', async () => {
		await joinPlanTasks('page-1', () => {});
		const ch = channels[0];
		const payload = { task_id: 'task-a' };
		expect(ch.onMessage('task.created', payload)).toBe(payload);
	});

	it('leaves the channel on cleanup', async () => {
		const cleanup = await joinPlanTasks('page-1', () => {});
		expect(channels[0].left).toBe(false);
		cleanup();
		expect(channels[0].left).toBe(true);
	});

	it('returns a noop and joins nothing when there is no socket', async () => {
		socketResult = null;
		const cleanup = await joinPlanTasks('page-1', () => {});
		expect(channels).toHaveLength(0);
		expect(() => cleanup()).not.toThrow();
	});
});

describe('joinBrainTasks', () => {
	it('joins the brain-scoped channel topic', async () => {
		await joinBrainTasks('brain-1', () => {});
		expect(channels).toHaveLength(1);
		expect(channels[0].topic).toBe('brain_tasks:brain-1');
		expect(channels[0].joined).toBe(true);
	});

	it('drives the callback on a task.* event (the overview refresh trigger)', async () => {
		const refresh = vi.fn();
		await joinBrainTasks('brain-1', refresh);
		channels[0].emit('task.created', { task_id: 'task-x' });
		expect(refresh).toHaveBeenCalledOnce();
		expect(refresh).toHaveBeenCalledWith({ event: 'task.created', taskId: 'task-x' });
	});
});
