<script lang="ts">
	import {
		Brain,
		Clock,
		FileText,
		Files,
		PanelRight,
		ScrollText,
		Settings,
		Users,
		X
	} from '@lucide/svelte';
	import { conversationJobs, type CompanionSpec } from '$lib/ash/api';
	import type { ConversationStore } from '$lib/chat/conversation-store.svelte';
	import PromptsPanel from './prompts-panel.svelte';
	import BrainsPanel from './brains-panel.svelte';
	import DraftsPanel from './drafts-panel.svelte';
	import FilesPanel from './files-panel.svelte';
	import SettingsPanel from './settings-panel.svelte';
	import JobsPanel from './jobs-panel.svelte';
	import MembersPanel from './members-panel.svelte';

	let {
		store,
		onCompanionRequest
	}: {
		store: ConversationStore;
		onCompanionRequest?: (spec: CompanionSpec) => void;
	} = $props();

	type PanelId = 'prompts' | 'brains' | 'drafts' | 'files' | 'members' | 'settings' | 'jobs';

	let open = $state(false);
	let activePanel = $state<PanelId>('prompts');
	let hasJobs = $state(false);
	let jobsChecked = $state(false);
	let container = $state<HTMLDivElement | null>(null);

	// Classic shows the jobs icon only when the conversation has active jobs;
	// checked lazily on first open, once per conversation.
	$effect(() => {
		void store.conversationId;
		hasJobs = false;
		jobsChecked = false;
	});

	function toggle() {
		open = !open;
		if (open && !jobsChecked) {
			jobsChecked = true;
			const targetId = store.conversationId;
			void conversationJobs(targetId).then((result) => {
				// Drop stale responses after a conversation switch mid-flight.
				if (store.conversationId !== targetId) return;
				if (result.success) hasJobs = result.data.length > 0;
			});
		}
	}

	// Close on outside click; clicks inside the popover keep it open.
	$effect(() => {
		if (!open) return;
		const onPointerDown = (event: PointerEvent) => {
			if (container && !container.contains(event.target as Node)) open = false;
		};
		document.addEventListener('pointerdown', onPointerDown);
		return () => document.removeEventListener('pointerdown', onPointerDown);
	});

	function onKeydown(event: KeyboardEvent) {
		if (event.key === 'Escape' && open) open = false;
	}

	// Opening a companion from a panel closes the rail, so the companion is
	// visible — essential below md, where the rail is a full-height bottom sheet
	// that would otherwise cover the companion it just opened.
	function requestCompanion(spec: CompanionSpec) {
		onCompanionRequest?.(spec);
		open = false;
	}

	const panels = $derived([
		{ id: 'prompts' as const, icon: ScrollText, label: 'Prompts', visible: true },
		{ id: 'brains' as const, icon: Brain, label: 'Brains', visible: true },
		{ id: 'drafts' as const, icon: FileText, label: 'Drafts', visible: true },
		{ id: 'files' as const, icon: Files, label: 'Files', visible: true },
		{ id: 'members' as const, icon: Users, label: 'Members', visible: true },
		{ id: 'settings' as const, icon: Settings, label: 'Settings', visible: true },
		{ id: 'jobs' as const, icon: Clock, label: 'Jobs', visible: hasJobs }
	]);
</script>

<svelte:window onkeydown={onKeydown} />

<div class="relative" bind:this={container}>
	<button
		type="button"
		class="wb-pill-btn shrink-0 {open ? 'wb-pill-btn-active' : ''}"
		data-testid="right-rail-toggle"
		aria-label="Tools"
		aria-expanded={open}
		onclick={toggle}
	>
		<PanelRight class="size-3.5" />
		<span class="hidden md:inline">Tools</span>
	</button>

	{#if open}
		<!-- Below md the rest is dimmed so the panel reads as a bottom sheet. -->
		<button
			type="button"
			class="fixed inset-0 z-40 bg-black/50 md:hidden"
			aria-label="Close tools"
			onclick={() => (open = false)}
		></button>

		<!-- Bottom sheet below md; anchored popover at md+. -->
		<div
			class="fixed inset-x-0 bottom-0 z-50 flex h-[85dvh] flex-col overflow-hidden rounded-t-2xl border bg-popover text-popover-foreground shadow-lg md:absolute md:inset-x-auto md:bottom-auto md:right-0 md:top-full md:mt-1 md:h-[28rem] md:w-[min(28rem,calc(100vw-1rem))] md:rounded-lg"
			data-testid="right-rail"
		>
			<!-- Sheet header (mobile only): label + dismiss. -->
			<div class="flex shrink-0 items-center justify-between border-b px-4 py-3 md:hidden">
				<span class="text-sm font-semibold">Tools</span>
				<button
					type="button"
					class="wb-pill-btn wb-pill-btn-square"
					aria-label="Close tools"
					onclick={() => (open = false)}
				>
					<X class="size-3.5" />
				</button>
			</div>

			<div class="flex min-h-0 flex-1">
				<nav
					class="flex w-12 shrink-0 flex-col items-center gap-1 border-r py-2"
					aria-label="Tool panels"
				>
					{#each panels.filter((panel) => panel.visible) as panel (panel.id)}
						<button
							type="button"
							class="inline-flex size-9 items-center justify-center rounded-lg transition-colors md:size-8 {activePanel ===
							panel.id
								? 'bg-secondary text-foreground'
								: 'text-muted-foreground hover:bg-accent/60 hover:text-foreground'}"
							title={panel.label}
							aria-label={panel.label}
							aria-pressed={activePanel === panel.id}
							data-testid="rail-tab-{panel.id}"
							onclick={() => (activePanel = panel.id)}
						>
							<panel.icon class="size-4" />
						</button>
					{/each}
				</nav>

				<div class="flex min-w-0 flex-1 flex-col">
					{#if activePanel === 'prompts'}
						<!-- Completed actions close the rail (like requestCompanion above):
						     their effect lands in the composer/conversation, which the
						     bottom sheet would otherwise cover on mobile. -->
						<PromptsPanel
							conversationId={store.conversationId}
							onInsert={(text) => {
								store.requestInsertText(text);
								open = false;
							}}
							onActivated={() => (open = false)}
						/>
					{:else if activePanel === 'brains'}
						<BrainsPanel onCompanionRequest={requestCompanion} />
					{:else if activePanel === 'drafts'}
						<DraftsPanel
							conversationId={store.conversationId}
							onCompanionRequest={requestCompanion}
						/>
					{:else if activePanel === 'files'}
						<FilesPanel conversationId={store.conversationId} />
					{:else if activePanel === 'members'}
						<MembersPanel conversationId={store.conversationId} />
					{:else if activePanel === 'settings'}
						<SettingsPanel conversationId={store.conversationId} />
					{:else if activePanel === 'jobs'}
						<JobsPanel conversationId={store.conversationId} />
					{/if}
				</div>
			</div>
		</div>
	{/if}
</div>
