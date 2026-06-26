<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { Bot, Brain, File, FileText, MessageSquare, ScrollText } from '@lucide/svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import type { WorkbenchTab } from '$lib/ash/api';

	// Mirrors the workbench LabelResolver.icon_for/1 per-type tab icons.
	const TYPE_ICONS: Record<string, typeof FileText> = {
		conversation: MessageSquare,
		brain_page: FileText,
		brain: Brain,
		agent: Bot,
		prompt: ScrollText,
		file: File
	};

	function tabIcon(type: string): typeof FileText {
		return TYPE_ICONS[type] ?? File;
	}

	function tabLabel(tab: WorkbenchTab): string {
		if (typeof tab.primary.label === 'string' && tab.primary.label) return tab.primary.label;
		if (tab.primary.type === 'conversation') {
			return tab.primary.id === 'new' ? 'New chat' : workbench.conversationTitle(tab.primary.id);
		}
		return tab.primary.type.replace(/_/g, ' ');
	}

	async function activate(tab: WorkbenchTab) {
		await workbench.activateTab(tab.id);
		if (tab.primary.type === 'conversation' && tab.primary.id !== 'new') {
			await goto(`${base}/chat/${tab.primary.id}`);
		}
	}

	async function close(event: MouseEvent, tab: WorkbenchTab) {
		event.stopPropagation();
		const wasActive = workbench.activeTabId === tab.id;
		await workbench.closeTab(tab.id);

		if (wasActive) {
			const next = workbench.tabs.at(-1);
			if (next?.primary.type === 'conversation' && next.primary.id !== 'new') {
				await goto(`${base}/chat/${next.primary.id}`);
			} else {
				await goto(`${base}/chat`);
			}
		}
	}

	// Classic's VerticalWheelToHorizontal hook: the strip scrolls
	// horizontally with a normal mouse wheel.
	function onWheel(event: WheelEvent) {
		const strip = event.currentTarget as HTMLElement;
		if (Math.abs(event.deltaY) > Math.abs(event.deltaX) && strip.scrollWidth > strip.clientWidth) {
			event.preventDefault();
			strip.scrollLeft += event.deltaY;
		}
	}
</script>

{#if workbench.tabs.length > 0}
	<!-- Mirrors the classic tab_bar.ex: flexible 180px tabs (96-220px), hidden
	     scrollbar, always-faded close button. -->
	<div
		class="wb-scroll flex items-center gap-1 overflow-x-auto border-b px-2 py-1.5"
		role="tablist"
		aria-label="Open tabs"
		data-testid="tab-bar"
		onwheel={onWheel}
	>
		{#each workbench.tabs as tab (tab.id)}
			{@const TabIcon = tabIcon(tab.primary.type)}
			<div
				class="flex min-w-[96px] max-w-[220px] basis-[180px] cursor-pointer items-center gap-1.5 rounded-md py-1 pl-3 pr-1 text-sm transition-colors {workbench.activeTabId ===
				tab.id
					? 'bg-accent font-medium text-accent-foreground'
					: 'text-muted-foreground hover:bg-accent/60 hover:text-secondary-foreground'}"
				role="tab"
				tabindex="0"
				aria-selected={workbench.activeTabId === tab.id}
				onclick={() => void activate(tab)}
				onkeydown={(event) => {
					if (event.key === 'Enter' || event.key === ' ') {
						event.preventDefault();
						void activate(tab);
					}
				}}
			>
				<TabIcon class="size-3.5 shrink-0 opacity-60" />
				<span class="min-w-0 flex-1 truncate">{tabLabel(tab)}</span>
				<button
					type="button"
					class="flex size-6 shrink-0 items-center justify-center rounded opacity-50 transition-opacity hover:bg-accent hover:opacity-100"
					aria-label="Close tab"
					onclick={(event) => void close(event, tab)}
				>
					×
				</button>
			</div>
		{/each}
	</div>
{/if}
