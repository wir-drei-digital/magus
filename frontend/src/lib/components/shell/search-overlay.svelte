<script lang="ts">
	import { Search } from '@lucide/svelte';
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';

	let { open = $bindable(false) }: { open?: boolean } = $props();

	let query = $state('');
	let inputEl = $state<HTMLInputElement | null>(null);
	let previouslyFocused: HTMLElement | null = null;

	// Dialog focus management: move focus into the field on open, return it to the
	// opener on close (WCAG 2.4.3). Runs after render, so inputEl and the opener
	// are both resolved when it fires.
	$effect(() => {
		if (open) {
			previouslyFocused = document.activeElement as HTMLElement | null;
			query = '';
			inputEl?.focus();
		} else if (previouslyFocused) {
			previouslyFocused.focus?.();
			previouslyFocused = null;
		}
	});

	/** Enter jumps to the full results route (SPA navigation). */
	function submit() {
		const trimmed = query.trim();
		if (trimmed.length >= 2) {
			void goto(`${base}/search?q=${encodeURIComponent(trimmed)}`);
		} else if (trimmed === '') {
			void goto(`${base}/search`);
		}
		open = false;
	}

	function onKeydown(event: KeyboardEvent) {
		if (event.key === 'Escape' && open) {
			event.preventDefault();
			open = false;
		}
	}
</script>

<svelte:window onkeydown={onKeydown} />

{#if open}
	<!-- Classic global-search-overlay: backdrop blur, bar at 15vh. -->
	<div
		class="fixed inset-0 z-50 flex items-start justify-center bg-background/80 pt-[15vh] backdrop-blur-sm"
		data-testid="search-overlay"
		role="presentation"
		onclick={(event) => {
			if (event.target === event.currentTarget) open = false;
		}}
	>
		<div
			class="flex w-full max-w-2xl items-center gap-3 rounded-xl border bg-secondary px-4 py-3 shadow-2xl"
			role="dialog"
			aria-modal="true"
			aria-label="Search"
		>
			<Search class="size-5 shrink-0 text-muted-foreground" />
			<input
				bind:this={inputEl}
				bind:value={query}
				placeholder="Search messages, conversations, blocks, files..."
				aria-label="Search"
				data-testid="search-overlay-input"
				class="flex-1 bg-transparent text-lg outline-none placeholder:text-muted-foreground"
				onkeydown={(event) => {
					if (event.key === 'Enter') submit();
					else if (event.key === 'Tab') event.preventDefault();
				}}
			/>
			<kbd
				class="rounded border border-input bg-background px-1.5 py-0.5 text-[10px] text-muted-foreground"
			>
				esc
			</kbd>
		</div>
	</div>
{/if}
