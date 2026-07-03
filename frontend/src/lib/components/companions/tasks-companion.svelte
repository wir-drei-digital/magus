<script lang="ts">
	import { ListChecks } from '@lucide/svelte';
	import TasksList from '$lib/components/chat/tasks-list.svelte';
	import CompanionFrame from './companion-frame.svelte';

	let { conversationId, onClose }: { conversationId: string; onClose: () => void } = $props();
</script>

<CompanionFrame title="Tasks" {onClose}>
	{#snippet icon()}
		<ListChecks class="size-4 shrink-0 text-muted-foreground" />
	{/snippet}

	<div class="flex min-h-0 flex-1 flex-col" data-testid="tasks-companion">
		<TasksList {conversationId} />
	</div>
</CompanionFrame>
