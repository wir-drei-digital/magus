<script lang="ts" module>
	import { Terminal, Plus } from '@lucide/svelte';

	/**
	 * A resolved assignee, independent of the raw task fields so the chip stays
	 * pure and testable. The board derives this from a task + a current-user /
	 * custom-agent lookup (see `resolveAssignee` in `plan-board.svelte.ts`).
	 *
	 *  - `human`    → a circular initials avatar + name ("You" for self).
	 *  - `external` → a terminal-styled monospace chip (e.g. `claude-code`),
	 *                 the signature treatment for agents acting over the API/CLI.
	 *  - `agent`    → an in-app custom agent: a colored pill, hue derived from
	 *                 the name so "Atlas"/"Scout" stay visually distinct.
	 */
	export type Assignee =
		| { kind: 'human'; name: string; self: boolean }
		| { kind: 'external'; label: string }
		| { kind: 'agent'; name: string };

	/** First letters of the first two whitespace-separated words, uppercased. */
	export function initials(name: string): string {
		const parts = name.trim().split(/\s+/).filter(Boolean);
		if (parts.length === 0) return '?';
		if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
		return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
	}

	// A small fixed palette for in-app agents; pick deterministically by name so
	// the same agent always reads the same color across cards and the overview.
	const AGENT_HUES = [
		'bg-teal-500/15 text-teal-600 dark:text-teal-300 ring-teal-500/30',
		'bg-pink-500/15 text-pink-600 dark:text-pink-300 ring-pink-500/30',
		'bg-violet-500/15 text-violet-600 dark:text-violet-300 ring-violet-500/30',
		'bg-amber-500/15 text-amber-600 dark:text-amber-300 ring-amber-500/30',
		'bg-sky-500/15 text-sky-600 dark:text-sky-300 ring-sky-500/30',
		'bg-emerald-500/15 text-emerald-600 dark:text-emerald-300 ring-emerald-500/30'
	];

	export function agentHue(name: string): string {
		let hash = 0;
		for (let i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) | 0;
		return AGENT_HUES[Math.abs(hash) % AGENT_HUES.length];
	}
</script>

<script lang="ts">
	let {
		assignee,
		class: className = ''
	}: {
		assignee: Assignee;
		class?: string;
	} = $props();
</script>

{#if assignee.kind === 'human'}
	<span
		data-testid="assignee-chip"
		data-assignee-kind="human"
		class="inline-flex items-center gap-1.5 text-xs text-secondary-foreground {className}"
	>
		<span
			class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary/15 text-[10px] font-semibold text-primary-link ring-1 ring-primary/25"
			aria-hidden="true"
		>
			{initials(assignee.name)}
		</span>
		<span class="truncate font-medium">{assignee.self ? 'You' : assignee.name}</span>
	</span>
{:else if assignee.kind === 'external'}
	<!-- Terminal treatment: monospace, a bracketed prompt glyph, warm tint:	     instantly readable as "an agent on the wire", not a person. -->
	<span
		data-testid="assignee-chip"
		data-assignee-kind="external"
		class="inline-flex items-center gap-1 rounded-md bg-orange-500/10 px-1.5 py-0.5 font-mono text-[11px] font-medium text-orange-600 ring-1 ring-orange-500/25 ring-inset dark:text-orange-300 {className}"
	>
		<Terminal class="size-3 shrink-0" />
		<span class="truncate">{assignee.label}</span>
	</span>
{:else}
	<span
		data-testid="assignee-chip"
		data-assignee-kind="agent"
		class="inline-flex items-center gap-1 rounded-full px-1.5 py-0.5 text-[11px] font-medium ring-1 ring-inset {agentHue(
			assignee.name
		)} {className}"
	>
		<Plus class="size-3 shrink-0" />
		<span class="truncate">{assignee.name}</span>
	</span>
{/if}
