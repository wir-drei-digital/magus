<script lang="ts">
	import { Menu } from '@lucide/svelte';
	import { cn } from '$lib/utils';
	import { navDrawer } from '$lib/stores/nav-drawer.svelte';

	let { class: className = '' }: { class?: string } = $props();
</script>

<!-- Inline mobile nav trigger: pane headers render it as their first item
     (hidden at md+), replacing the old floating hamburger that every header
     had to clear with pl-14. -->
<button
	type="button"
	class={cn(
		'flex size-7 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground md:hidden',
		className
	)}
	aria-label="Open navigation"
	data-testid="mobile-menu"
	onclick={() => (navDrawer.open = true)}
>
	<Menu class="size-[18px]" />
</button>
