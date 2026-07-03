<script lang="ts">
	import type { Snippet } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import LibraryGallery from './components/library-gallery.svelte';

	let { children }: { children: Snippet } = $props();

	// The gallery lives here (not in +page) so it stays mounted across
	// /library <-> /library/*/[id]: selecting a card narrows it into a master
	// rail and the reader opens beside it. Scroll position and filters survive,
	// and deep links + the back button work.
	const selectedId = $derived(page.params.promptId ?? page.params.skillId ?? null);
	const readerOpen = $derived(selectedId !== null);

	// Deep links into an item put the workbench in library mode once; afterwards
	// the mode strip can switch freely.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'library') void workbench.setMode('library');
	});

	// ?new=skill comes from the /skills/new redirect; ?new=prompt is supported
	// symmetrically (the /prompts/new route resolves via [promptId] to plain
	// /library). Either opens the matching create dialog once, then strips the param.
	let newParamApplied = false;
	$effect(() => {
		if (newParamApplied) return;
		const kind = page.url.searchParams.get('new');
		newParamApplied = true;
		if (kind === 'skill') libraryNav.createSkillOpen = true;
		if (kind === 'prompt') libraryNav.createPromptOpen = true;
		if (kind) {
			const url = new URL(page.url);
			url.searchParams.delete('new');
			void goto(`${url.pathname}${url.search}`, { replaceState: true });
		}
	});
</script>

<svelte:head>
	<title>Magus — Library</title>
</svelte:head>

<div class="flex h-full min-h-0" data-testid="library-view">
	<!-- Full width at rest; a master rail when a reader is open. On narrow
	     screens the reader takes the whole pane, so the gallery hides. -->
	<div
		class="flex min-h-0 min-w-0 flex-col {readerOpen
			? 'hidden md:flex md:w-[44%] md:shrink-0 lg:w-[40%]'
			: 'flex-1'}"
	>
		<LibraryGallery {selectedId} compact={readerOpen} />
	</div>

	{#if readerOpen}
		<div class="min-h-0 min-w-0 flex-1 md:border-l">
			{@render children()}
		</div>
	{/if}
</div>
