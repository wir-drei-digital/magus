<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { ArrowLeft, ScrollText, Sparkles, Star } from '@lucide/svelte';
	import {
		addPromptTags,
		destroyPrompt,
		favoritePrompt,
		getPrompt,
		incrementPromptUseCount,
		listTags,
		myPromptFavorites,
		publishPrompt,
		removePromptTag,
		sharePromptToTeam,
		unfavoritePrompt,
		unpublishPrompt,
		unsharePromptFromTeam,
		type PromptDetail,
		type TagEntry
	} from '$lib/ash/api';
	import { saveDraft } from '$lib/chat/drafts';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import { Button, confirmAction } from '$lib/components/crud';
	import PromptFormDialog from '$lib/components/shell/prompt-form-dialog.svelte';

	const promptId = $derived(page.params.promptId!);
	const isNew = $derived(promptId === 'new');

	let prompt = $state<PromptDetail | null>(null);
	let loadError = $state<string | null>(null);
	// Share / publish / delete failures surface in this banner.
	let saveError = $state<string | null>(null);

	// ?edit=true deep links open straight into the edit dialog (classic parity),
	// then strip the param so it doesn't leak back into the gallery hrefs.
	let editOpen = $state(false);
	let editParamApplied = false;
	$effect(() => {
		if (editParamApplied || !prompt) return;
		editParamApplied = true;
		if (page.url.searchParams.get('edit') === 'true') {
			editOpen = true;
			const url = new URL(page.url);
			url.searchParams.delete('edit');
			void goto(`${url.pathname}${url.search}`, { replaceState: true });
		}
	});

	let tags = $state<TagEntry[]>([]);

	// Only offer tags in the prompt's scope: its workspace's shared tags, or
	// the viewer's personal tags for personal prompts.
	const scopedTags = $derived(
		tags.filter((tag) => (tag.workspaceId ?? null) === (prompt?.workspaceId ?? null))
	);

	$effect(() => {
		const id = promptId;
		prompt = null;
		loadError = null;

		// Creation lives in the shared "New prompt" dialog; this route only reads.
		if (id === 'new') {
			void goto(`${base}/library`, { replaceState: true });
			return;
		}

		void getPrompt(id).then((result) => {
			if (id !== promptId) return;
			if (result.success) {
				prompt = result.data;
			} else {
				loadError = result.errors[0]?.message ?? 'Prompt could not be loaded';
			}
		});
		void listTags().then((result) => {
			if (result.success) tags = result.data;
		});
	});

	async function remove() {
		if (!prompt) return;
		const ok = await confirmAction({
			title: `Delete ${prompt.name}?`,
			description: 'This prompt will be permanently removed from your library.',
			confirmLabel: 'Delete'
		});
		if (!ok) return;
		const result = await destroyPrompt(promptId);
		if (result.success) {
			libraryNav.refresh();
			await goto(`${base}/library`);
		} else {
			saveError = result.errors[0]?.message ?? 'Prompt could not be deleted';
		}
	}

	async function toggleFavorite() {
		if (!prompt) return;
		const id = promptId;
		if (prompt.isFavorited) {
			// The favorite row id comes from the favorites listing.
			const favorites = await myPromptFavorites();
			if (!favorites.success) return;
			const favorite = favorites.data.find((entry) => entry.promptId === prompt!.id);
			if (favorite) await unfavoritePrompt(favorite.id);
		} else {
			await favoritePrompt(prompt.id);
		}
		const refreshed = await getPrompt(id);
		// Drop stale responses after navigating to another prompt mid-flight.
		if (id === promptId && refreshed.success) prompt = refreshed.data;
		libraryNav.refresh();
	}

	async function toggleShare() {
		if (!prompt) return;
		const result = prompt.isSharedToWorkspace
			? await unsharePromptFromTeam(prompt.id)
			: await sharePromptToTeam(prompt.id);
		if (result.success) {
			prompt = result.data;
			libraryNav.refresh();
		} else {
			saveError = result.errors[0]?.message ?? 'Sharing failed';
		}
	}

	async function togglePublish() {
		if (!prompt) return;
		const result = prompt.isPublic
			? await unpublishPrompt(prompt.id)
			: await publishPrompt(prompt.id);
		if (result.success) prompt = result.data;
		else saveError = result.errors[0]?.message ?? 'Publishing failed';
	}

	/** Classic "Use prompt": start a fresh chat seeded with the content. */
	async function usePrompt() {
		if (!prompt) return;
		const conversation = await workbench.createConversation();
		if (!conversation) return;
		// The composer restores its localStorage draft on mount.
		saveDraft(localStorage, conversation.id, prompt.content);
		void incrementPromptUseCount(prompt.id);
		await goto(`${base}/chat/${conversation.id}`);
	}

	async function toggleTag(tag: { id: string; name: string }) {
		if (!prompt) return;
		const hasTag = prompt.tags.some((entry) => entry.id === tag.id);
		const result = hasTag
			? await removePromptTag(prompt.id, tag.id)
			: await addPromptTags(prompt.id, [tag.id]);
		if (result.success) prompt = result.data;
	}
</script>

<svelte:head>
	<title>Magus — {isNew ? 'New prompt' : (prompt?.name ?? 'Prompt')}</title>
</svelte:head>

<div class="flex h-full min-h-0 flex-col" data-testid="prompt-detail">
	{#if loadError}
		<p class="p-6 text-sm text-destructive">{loadError}</p>
	{:else if !prompt}
		<div class="space-y-3 p-6">
			<div class="h-5 w-1/3 animate-pulse rounded bg-muted"></div>
			<div class="h-40 animate-pulse rounded-xl bg-muted"></div>
		</div>
	{:else}
		{#if saveError}
			<p class="border-b bg-destructive/10 px-6 py-1.5 text-xs text-destructive">{saveError}</p>
		{/if}
		<header class="flex min-h-11 shrink-0 items-center gap-2.5 border-b py-2 pr-6 pl-14 md:pl-4">
			<button
				type="button"
				class="wb-pill-btn wb-pill-btn-square shrink-0"
				aria-label="Back to library"
				data-testid="reader-back"
				onclick={() => void goto(`${base}/library${page.url.search}`)}
			>
				<ArrowLeft class="size-4" />
			</button>
			<span
				class="flex size-6 shrink-0 items-center justify-center rounded-full border border-input bg-secondary"
				title={prompt.type === 'system' ? 'System prompt' : 'User prompt'}
			>
				{#if prompt.type === 'system'}
					<Sparkles class="size-3.5 text-muted-foreground" />
				{:else}
					<ScrollText class="size-3.5 text-muted-foreground" />
				{/if}
			</span>
			<div class="flex min-w-0 flex-1 items-baseline gap-2">
				<h1 class="min-w-0 truncate text-sm font-semibold" data-testid="prompt-title">
					{prompt.name}
				</h1>
				<p class="min-w-0 truncate text-xs text-muted-foreground max-md:hidden">
					{#if prompt.description}{prompt.description} ·
					{/if}Used {prompt.useCount}
					{prompt.useCount === 1 ? 'time' : 'times'}
				</p>
			</div>
			<div class="flex shrink-0 items-center gap-1.5">
				<button
					type="button"
					class="wb-pill-btn wb-pill-btn-square shrink-0 {prompt.isFavorited
						? '!text-favorite'
						: ''}"
					aria-label={prompt.isFavorited ? 'Unfavorite' : 'Favorite'}
					data-testid="prompt-favorite"
					onclick={() => void toggleFavorite()}
				>
					<Star class="size-3.5 {prompt.isFavorited ? 'fill-favorite' : ''}" />
				</button>
				<Button size="sm" data-testid="prompt-use" onclick={() => void usePrompt()}
					>Use prompt</Button
				>
				<button
					type="button"
					class="wb-pill-btn shrink-0"
					data-testid="prompt-edit"
					onclick={() => (editOpen = true)}
				>
					Edit
				</button>
				<DropdownMenu.Root>
					<DropdownMenu.Trigger
						class="wb-pill-btn wb-pill-btn-square shrink-0"
						aria-label="Prompt actions"
					>
						⋯
					</DropdownMenu.Trigger>
					<DropdownMenu.Content align="end">
						<DropdownMenu.Item onSelect={() => void togglePublish()}>
							{prompt.isPublic ? 'Unpublish from library' : 'Publish to library'}
						</DropdownMenu.Item>
						{#if session.user?.currentWorkspaceId}
							<DropdownMenu.Item onSelect={() => void toggleShare()}>
								{prompt.isSharedToWorkspace ? 'Unshare from workspace' : 'Share to workspace'}
							</DropdownMenu.Item>
						{/if}
						<DropdownMenu.Separator />
						<DropdownMenu.Item variant="destructive" onSelect={() => void remove()}>
							Delete
						</DropdownMenu.Item>
					</DropdownMenu.Content>
				</DropdownMenu.Root>
			</div>
		</header>

		<div class="wb-scroll mx-auto w-full max-w-2xl min-h-0 flex-1 overflow-y-auto p-6">
			<div class="mb-4 flex flex-wrap items-center gap-1.5">
				<span
					class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium capitalize text-secondary-foreground"
				>
					{prompt.type} prompt
				</span>
				{#if prompt.chatMode}
					<span
						class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium capitalize text-secondary-foreground"
					>
						{prompt.chatMode.replace('_', ' ')}
					</span>
				{/if}
				{#if prompt.isPublic}
					<span
						class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground"
					>
						Public
					</span>
				{/if}
				{#if prompt.isSharedToWorkspace}
					<span
						class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground"
					>
						Workspace
					</span>
				{/if}
				{#each prompt.tags as tag (tag.id)}
					<button
						type="button"
						class="rounded-full bg-primary/10 px-2 py-0.5 text-[10px] font-medium text-primary transition-colors hover:bg-primary/20"
						aria-label="Remove tag {tag.name}"
						title="Remove tag"
						onclick={() => void toggleTag(tag)}
					>
						#{tag.name} ×
					</button>
				{/each}
				{#if scopedTags.filter((tag) => !prompt?.tags.some((t) => t.id === tag.id)).length > 0}
					<DropdownMenu.Root>
						<DropdownMenu.Trigger
							class="rounded-full border border-dashed border-input px-2 py-0.5 text-[10px] text-muted-foreground transition-colors hover:text-foreground"
							aria-label="Add tag"
						>
							+ tag
						</DropdownMenu.Trigger>
						<DropdownMenu.Content align="start">
							{#each scopedTags.filter((tag) => !prompt?.tags.some((t) => t.id === tag.id)) as tag (tag.id)}
								<DropdownMenu.Item onSelect={() => void toggleTag(tag)}>
									#{tag.name}
								</DropdownMenu.Item>
							{/each}
						</DropdownMenu.Content>
					</DropdownMenu.Root>
				{/if}
			</div>

			<pre
				class="whitespace-pre-wrap rounded-xl border border-input bg-card/60 p-4 font-mono text-sm leading-relaxed"
				data-testid="prompt-content">{prompt.content}</pre>
		</div>
	{/if}
</div>

<PromptFormDialog bind:open={editOpen} {prompt} onSaved={(updated) => (prompt = updated)} />
