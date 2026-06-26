<script lang="ts">
	import { Brain } from '@lucide/svelte';
	import Markdown from './markdown.svelte';

	let { text }: { text: string } = $props();

	// Short preview shown on the summary line (parity with the workbench
	// streaming_thinking_indicator: first ~60 chars, newlines flattened).
	const preview = $derived.by(() => {
		const flat = text.slice(0, 60).replace(/\n/g, ' ');
		return text.length > 60 ? `${flat}…` : flat;
	});

	// Keep the reasoning body pinned to the newest text as it streams in.
	let body = $state<HTMLDivElement | null>(null);
	$effect(() => {
		void text;
		if (body) body.scrollTop = body.scrollHeight;
	});
</script>

<details class="group ml-1 w-full max-w-[92%]" open data-testid="streaming-reasoning">
	<summary
		class="flex cursor-pointer list-none items-center gap-2 text-sm text-muted-foreground select-none hover:text-foreground/70 [&::-webkit-details-marker]:hidden"
	>
		<Brain class="size-4 shrink-0 animate-pulse text-info" />
		<span>Reasoning…</span>
		<span
			class="max-w-md truncate rounded bg-foreground/5 px-2 py-0.5 font-mono text-xs text-muted-foreground/70"
		>
			{preview}
		</span>
	</summary>
	<div
		bind:this={body}
		class="mt-2 ml-2 max-h-64 overflow-y-auto border-l border-input pl-3 text-xs"
	>
		<Markdown {text} streaming />
	</div>
</details>
