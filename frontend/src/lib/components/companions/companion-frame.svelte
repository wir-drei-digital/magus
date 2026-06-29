<script lang="ts">
	import type { Snippet } from 'svelte';
	import { X } from '@lucide/svelte';

	let {
		title,
		meta = null,
		pill = null,
		icon = null,
		onClose,
		onRename,
		headerActions = null,
		children,
		footer = null
	}: {
		title: string;
		meta?: string | null;
		/** Scope badge (e.g. "Workspace" / "Personal"). */
		pill?: string | null;
		icon?: Snippet | null;
		onClose: () => void;
		/** When set, the title becomes click-to-rename. */
		onRename?: (title: string) => void;
		/** Right-aligned header content (e.g. presence avatars), before the pill. */
		headerActions?: Snippet | null;
		children: Snippet;
		footer?: Snippet | null;
	} = $props();

	let renaming = $state(false);
	let titleDraft = $state('');

	function commitRename() {
		if (!renaming) return;
		renaming = false;
		const next = titleDraft.trim();
		if (next && next !== title) onRename?.(next);
	}
</script>

<div class="flex h-full min-h-0 flex-col bg-background" data-testid="companion-pane">
	<!-- pl-14 on mobile clears the floating hamburger during a full-width
	     companion takeover; desktop keeps the normal padding. -->
	<header class="flex shrink-0 items-center gap-2 border-b py-2.5 pr-4 pl-14 md:pl-4">
		{#if icon}
			{@render icon()}
		{/if}
		{#if onRename && renaming}
			<!-- svelte-ignore a11y_autofocus — transient rename input -->
			<input
				bind:value={titleDraft}
				autofocus
				data-testid="companion-title-input"
				class="min-w-0 flex-1 rounded-md border border-input bg-secondary px-2 py-0.5 text-sm font-semibold outline-none focus:border-primary/60"
				onblur={commitRename}
				onkeydown={(event) => {
					if (event.key === 'Enter') commitRename();
					if (event.key === 'Escape') renaming = false;
				}}
			/>
		{:else if onRename}
			<div class="min-w-0 flex-1">
				<button
					type="button"
					class="block max-w-full truncate text-left text-sm font-semibold hover:underline"
					data-testid="companion-title"
					title="Rename"
					onclick={() => {
						titleDraft = title;
						renaming = true;
					}}
				>
					{title}
				</button>
				{#if meta}
					<p class="truncate text-xs text-muted-foreground">{meta}</p>
				{/if}
			</div>
		{:else}
			<div class="min-w-0 flex-1">
				<h2 class="truncate text-sm font-semibold" data-testid="companion-title">{title}</h2>
				{#if meta}
					<p class="truncate text-xs text-muted-foreground">{meta}</p>
				{/if}
			</div>
		{/if}
		{#if headerActions}
			<div class="shrink-0">{@render headerActions()}</div>
		{/if}
		{#if pill}
			<span
				class="shrink-0 rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground"
				data-testid="companion-pill"
			>
				{pill}
			</span>
		{/if}
		<button
			type="button"
			class="wb-pill-btn wb-pill-btn-square shrink-0"
			aria-label="Close companion"
			data-testid="companion-close"
			onclick={onClose}
		>
			<X class="size-3.5" />
		</button>
	</header>

	{@render children()}

	{#if footer}
		{@render footer()}
	{/if}
</div>
