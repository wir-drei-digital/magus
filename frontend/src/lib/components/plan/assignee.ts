/**
 * Shared assignee resolution for the plan board and the brain overview.
 *
 * A task carries only ids (`assignedToUserId` / `assignedToAgent` /
 * `assignedToCustomAgentId`); both surfaces need to turn that into the resolved
 * {@link Assignee} descriptor the chip + worker card render. Centralised here so
 * the board and the overview stay in lock-step: same self-detection, same
 * in-app agent name lookup, same precedence.
 *
 * Precedence (a task is assigned to at most one of these in practice):
 *   1. in-app custom agent  → `agent`    (named, colored pill)
 *   2. external/CLI agent   → `external` (terminal-styled label, e.g. claude-code)
 *   3. human user           → `human`    (initials avatar, "You" when self)
 */
import { session } from '$lib/stores/session.svelte';
import type { Assignee } from './assignee-chip.svelte';

/** Fields needed to resolve an assignee: a structural subset of PlanTask. */
export type AssignableTask = {
	assignedToUserId: string | null;
	assignedToAgent: string | null;
	assignedToCustomAgentId: string | null;
};

/**
 * Resolve a task's assignment into a chip descriptor, or `null` when unassigned.
 *
 * @param task        the (subset of the) task carrying the assignee ids
 * @param agentNames  custom-agent id → display name (from `myAgents()`)
 */
export function resolveAssignee(
	task: AssignableTask,
	agentNames: Map<string, string>
): Assignee | null {
	if (task.assignedToCustomAgentId) {
		return { kind: 'agent', name: agentNames.get(task.assignedToCustomAgentId) ?? 'Agent' };
	}
	if (task.assignedToAgent) {
		return { kind: 'external', label: task.assignedToAgent };
	}
	if (task.assignedToUserId) {
		const self = task.assignedToUserId === session.user?.id;
		const name = self ? (session.user?.displayName ?? session.user?.email ?? 'You') : 'Teammate';
		return { kind: 'human', name, self };
	}
	return null;
}

/**
 * A stable identity key for an assignee, used to group in-progress tasks by
 * worker in the overview's IN FLIGHT section. Distinct workers (two different
 * external agents, a human vs. an agent of the same name) never collide.
 */
export function assigneeKey(assignee: Assignee): string {
	switch (assignee.kind) {
		case 'human':
			return `human:${assignee.self ? 'self' : assignee.name}`;
		case 'external':
			return `external:${assignee.label}`;
		case 'agent':
			return `agent:${assignee.name}`;
	}
}

/** Display name for an assignee (worker card title; "You" for self). */
export function assigneeName(assignee: Assignee): string {
	switch (assignee.kind) {
		case 'human':
			return assignee.self ? 'You' : assignee.name;
		case 'external':
			return assignee.label;
		case 'agent':
			return assignee.name;
	}
}

/** Muted type label under the worker name ("external agent · terminal", etc.). */
export function assigneeTypeLabel(assignee: Assignee): string {
	switch (assignee.kind) {
		case 'human':
			return 'human';
		case 'external':
			return 'external agent · terminal';
		case 'agent':
			return 'in-app agent';
	}
}
