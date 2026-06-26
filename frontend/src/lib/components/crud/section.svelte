<script lang="ts">
	import type { Snippet } from 'svelte';

	// A titled card section — the shared grouping container for every CRUD-like
	// surface (settings, workspaces, agents, prompts). Generalized from the old
	// `settings-section` with an optional header `actions` slot, an anchor `id`,
	// and a `danger` variant for destructive zones.
	let {
		title,
		description,
		children,
		actions,
		testid,
		id,
		variant = 'default'
	}: {
		title: string;
		description?: string;
		children: Snippet;
		actions?: Snippet;
		testid?: string;
		id?: string;
		variant?: 'default' | 'danger';
	} = $props();
</script>

<section
	{id}
	data-testid={testid}
	class="rounded-xl border bg-card p-5 {variant === 'danger' ? 'border-destructive/30' : ''}"
>
	<div class="mb-4 flex items-start justify-between gap-3">
		<div class="min-w-0">
			<h2 class="text-sm font-semibold {variant === 'danger' ? 'text-destructive' : ''}">
				{title}
			</h2>
			{#if description}
				<p class="mt-0.5 text-xs text-muted-foreground">{description}</p>
			{/if}
		</div>
		{#if actions}
			<div class="shrink-0">{@render actions()}</div>
		{/if}
	</div>
	{@render children()}
</section>
