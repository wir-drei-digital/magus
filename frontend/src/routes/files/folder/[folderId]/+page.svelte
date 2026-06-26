<script lang="ts">
	import { page } from '$app/state';
	import FileBrowser from '$lib/components/files/file-browser.svelte';
	import { joinWorkspaceFiles } from '$lib/realtime/workspace-files';
	import { filesStore } from '$lib/stores/files.svelte';
	import { notificationFeed } from '$lib/stores/notifications.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';

	const folderId = $derived(page.params.folderId!);

	$effect(() => {
		filesStore.restoreViewMode(session.user?.uiPreferences);
	});

	// One-shot: deep links sync the nav once; afterwards the mode strip
	// may switch the nav freely without this route forcing it back.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'files') void workbench.setMode('files');
	});

	$effect(() => {
		void filesStore.load('folder', {
			folderId,
			workspaceId: session.user?.currentWorkspaceId ?? null,
			userId: session.user?.id ?? null
		});
	});

	// First run only arms the tracker; later bumps trigger a refresh.
	let revisionArmed = false;
	$effect(() => {
		void notificationFeed.fileRevision;
		if (!revisionArmed) {
			revisionArmed = true;
			return;
		}
		filesStore.refresh();
	});

	$effect(() => {
		const workspaceId = session.user?.currentWorkspaceId;
		if (!workspaceId) return;

		// The join resolves async — if the effect was torn down first (fast
		// navigation), leave immediately instead of leaking the channel.
		let cancelled = false;
		let leave: (() => void) | null = null;

		void joinWorkspaceFiles(workspaceId, () => filesStore.refresh()).then((cleanup) => {
			if (cancelled) cleanup();
			else leave = cleanup;
		});

		return () => {
			cancelled = true;
			leave?.();
		};
	});
</script>

<svelte:head>
	<title>
		Magus — {filesStore.breadcrumbs.at(-1)?.name ?? 'Files'}
	</title>
</svelte:head>

<FileBrowser />
