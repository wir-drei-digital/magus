<script lang="ts">
	import { Menu } from '@lucide/svelte';
	import { cn } from '$lib/utils';
	import { navDrawer } from '$lib/stores/nav-drawer.svelte';

	let { class: className = '' }: { class?: string } = $props();
</script>

<!-- Inline mobile nav trigger: pane headers render it as their first item
     (hidden at md+), replacing the old floating hamburger that every header
     had to clear with pl-14. Same circular pill style as the other header
     icon buttons. -->
<button
	type="button"
	class={cn('wb-pill-btn wb-pill-btn-square shrink-0 md:!hidden', className)}
	aria-label="Open navigation"
	data-testid="mobile-menu"
	onclick={() => (navDrawer.open = true)}
>
	<Menu class="size-4" />
</button>
