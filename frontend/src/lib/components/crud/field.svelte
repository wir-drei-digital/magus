<script lang="ts">
	import type { Snippet } from 'svelte';

	// A labelled form field: a `<label>` wrapping its control so the association is
	// implicit (no id wiring), with optional hint and error text below. The control
	// goes in the default slot and should use `CONTROL_CLASS` / `TEXTAREA_CLASS`.
	let {
		label,
		hint,
		error = null,
		required = false,
		children,
		testid
	}: {
		label: string;
		hint?: string;
		error?: string | null;
		required?: boolean;
		children: Snippet;
		testid?: string;
	} = $props();
</script>

<label class="flex flex-col gap-1.5" data-testid={testid}>
	<span class="text-xs font-medium text-muted-foreground">
		{label}{#if required}<span class="text-destructive" aria-hidden="true">&nbsp;*</span>{/if}
	</span>
	{@render children()}
	{#if error}
		<span class="text-xs text-destructive">{error}</span>
	{:else if hint}
		<span class="text-xs text-muted-foreground">{hint}</span>
	{/if}
</label>
