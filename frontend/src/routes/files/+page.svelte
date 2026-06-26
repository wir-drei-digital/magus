<script lang="ts">
	import { page } from '$app/state';
	import FileBrowser from '$lib/components/files/file-browser.svelte';
	import { joinWorkspaceFiles } from '$lib/realtime/workspace-files';
	import { filesStore, type FilesScope } from '$lib/stores/files.svelte';
	import { notificationFeed } from '$lib/stores/notifications.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';

	const VALID_SCOPES = new Set<FilesScope>(['my_files', 'recent', 'templates', 'trash', 'shared']);

	const scope = $derived.by<FilesScope>(() => {
		const param = page.url.searchParams.get('scope') as FilesScope | null;
		return param && VALID_SCOPES.has(param) ? param : 'my_files';
	});

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
		void filesStore.load(scope, {
			workspaceId: session.user?.currentWorkspaceId ?? null,
			userId: session.user?.id ?? null
		});
	});

	// Channel-driven refresh: the user channel bridges the actor's own file/
	// folder events; the workspace channel adds other members' file events.
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
	<title>Magus — Files</title>
</svelte:head>

<FileBrowser />
