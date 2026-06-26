<script lang="ts">
	import type { Snippet } from 'svelte';
	import { cn } from '$lib/utils.js';

	let {
		icon,
		title,
		description,
		class: className,
		children,
		...rest
	}: {
		/** Optional icon snippet, rendered muted at size-8. */
		icon?: Snippet;
		/** Primary line (display face). */
		title: string;
		/** Optional secondary line (muted). */
		description?: string;
		class?: string;
		/** Optional action area, e.g. a button. */
		children?: Snippet;
		/** Forwarded to the root (e.g. a caller-specific data-testid). */
		[key: string]: unknown;
	} = $props();
</script>

<div
	data-testid="empty-state"
	{...rest}
	class={cn('flex h-full flex-col items-center justify-center gap-3 p-6 text-center', className)}
>
	{#if icon}
		<div class="text-muted-foreground/40 [&>svg]:size-8">{@render icon()}</div>
	{/if}
	<div class="space-y-1">
		<p class="font-display text-base font-semibold tracking-tight text-foreground">{title}</p>
		{#if description}
			<p class="max-w-sm text-sm text-muted-foreground">{description}</p>
		{/if}
	</div>
	{#if children}
		<div class="mt-1">{@render children()}</div>
	{/if}
</div>
