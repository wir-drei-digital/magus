<script lang="ts">
	import { BookMarked, Wrench, Box } from '@lucide/svelte';
	import type { SkillSummary } from '$lib/ash/api';

	let {
		skill,
		href,
		selected = false,
		compact = false
	}: {
		skill: SkillSummary;
		href: string;
		selected?: boolean;
		compact?: boolean;
	} = $props();

	const label = $derived(skill.displayName ?? skill.name);
	const toolCount = $derived(skill.requestedTools?.length ?? 0);
</script>

<a
	{href}
	data-testid="skill-card"
	data-selected={selected ? 'true' : undefined}
	class="flex h-full flex-col gap-2 rounded-xl border bg-card/50 p-3.5 transition-colors hover:border-primary/40 hover:bg-card focus-visible:border-primary/60 focus-visible:ring-2 focus-visible:ring-primary/50 focus-visible:outline-none {selected
		? 'border-primary/60 bg-card'
		: 'border-border'}"
>
	<div class="flex items-start gap-2">
		<BookMarked class="mt-0.5 size-4 shrink-0 text-primary" />
		<div class="min-w-0 flex-1">
			<p class="truncate text-sm font-medium">{label}</p>
			{#if skill.description && !compact}
				<p class="line-clamp-2 text-xs text-muted-foreground">{skill.description}</p>
			{/if}
		</div>
	</div>

	<div class="mt-auto flex flex-wrap items-center gap-1.5 pt-0.5">
		{#if skill.hasExecutableBundle}
			<span
				class="inline-flex items-center gap-1 rounded-full bg-amber-500/10 px-1.5 py-0.5 text-[10px] font-medium text-amber-600 dark:text-amber-400"
				title="Includes runnable code — executes in a sandbox"
			>
				<Box class="size-2.5" />
				sandbox
			</span>
		{/if}

		{#if toolCount > 0}
			<span
				class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-primary"
			>
				<Wrench class="size-2.5" />
				{toolCount}
				{toolCount === 1 ? 'tool' : 'tools'}
			</span>
		{/if}

		{#if skill.version && !compact}
			<span class="ml-auto shrink-0 text-[10px] text-muted-foreground">
				v{skill.version}
			</span>
		{/if}
	</div>
</a>
