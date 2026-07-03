<script lang="ts">
	import TasksList from '$lib/components/chat/tasks-list.svelte';

	let { conversationId }: { conversationId: string } = $props();
</script>

<div class="flex min-h-0 flex-1 flex-col" data-testid="rail-tasks-panel">
	<TasksList {conversationId} />
</div>
