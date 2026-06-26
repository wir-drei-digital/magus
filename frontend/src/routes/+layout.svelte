<script lang="ts">
	import '../app.css';
	import { untrack } from 'svelte';
	import type { Snippet } from 'svelte';
	import { afterNavigate } from '$app/navigation';
	import { Menu } from '@lucide/svelte';
	import { session } from '$lib/stores/session.svelte';
	import { notificationFeed } from '$lib/stores/notifications.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import ModeStrip from '$lib/components/shell/mode-strip.svelte';
	import NavPane from '$lib/components/shell/nav-pane.svelte';
	import TabBar from '$lib/components/shell/tab-bar.svelte';
	import ConfirmDialog from '$lib/components/shell/confirm-dialog.svelte';
	import ToastHost from '$lib/components/shell/toast-host.svelte';
	import { Button } from '$lib/components/ui/button';
	import { Card } from '$lib/components/ui/card';

	let { children }: { children: Snippet } = $props();

	// Mobile only: the left rail (mode strip + nav) collapses into a slide-in
	// drawer toggled by a floating hamburger. Desktop ignores this entirely
	// (the rail is statically positioned at md+).
	let drawerOpen = $state(false);

	// A nav tap that changes the route closes the drawer; mode switches that
	// only swap the nav pane in place keep it open so the user can pick an item.
	afterNavigate(() => {
		drawerOpen = false;
	});

	// Render immediately from local state; authenticate and go live in the
	// background — the SPA never blocks interaction on a connection.
	// untrack: this must run exactly once; any reactive read inside load()
	// would otherwise re-trigger it.
	$effect(() => {
		untrack(() => void session.load());
	});

	// Keyed on stable primitives, not the user object: optimistic preference
	// writes replace `session.user` wholesale, and an object-keyed effect
	// would reconnect + refetch the whole shell on every toggle. A derived
	// string only notifies when its value actually changes — this is also
	// what makes workspace switching work (the key includes the workspace).
	const sessionKey = $derived(
		session.status === 'authenticated' && session.user
			? `${session.user.id}|${session.user.currentWorkspaceId ?? ''}`
			: null
	);

	$effect(() => {
		if (!sessionKey) return;
		const user = untrack(() => session.user);
		if (!user) return;
		void notificationFeed.connect(user.id);
		void workbench.load(user.id, user.currentWorkspaceId);
		return () => notificationFeed.disconnect();
	});

	// Cross-device reconciliation: refetch shell state when the tab regains
	// focus (TabSession changes aren't broadcast during the migration).
	// Throttled — alt-tabbing back and forth would otherwise fire the full
	// shell reload (session + conversations + workspaces) on every focus,
	// and a refetch racing in-flight tab mutations widens the window for
	// stale-snapshot reconciliation.
	let lastFocusLoad = 0;
	$effect(() => {
		const onFocus = () => {
			if (session.status !== 'authenticated' || !session.user) return;
			if (Date.now() - lastFocusLoad < 30_000) return;
			lastFocusLoad = Date.now();
			void workbench.load(session.user.id, session.user.currentWorkspaceId);
		};
		window.addEventListener('focus', onFocus);
		return () => window.removeEventListener('focus', onFocus);
	});
</script>

<!-- Mirrors the classic workbench root: no top header — the mode strip owns
     logo, status, and account; the spectral canvas fills the shell. -->
<div class="bg-spectral flex h-dvh flex-col">
	{#if session.status === 'loading'}
		<div class="flex flex-1 items-center justify-center">
			<div class="h-4 w-48 animate-pulse rounded bg-muted"></div>
		</div>
	{:else if session.status === 'unauthenticated'}
		<div class="flex flex-1 items-center justify-center">
			<Card class="space-y-3 p-6">
				<p class="text-sm">You're not signed in.</p>
				<a href="/sign-in" data-sveltekit-reload>
					<Button>Sign in</Button>
				</a>
			</Card>
		</div>
	{:else if session.status === 'error'}
		<div class="flex flex-1 items-center justify-center">
			<Card class="p-6">
				<p class="text-sm text-destructive">Couldn't reach the server. Retrying may help.</p>
			</Card>
		</div>
	{:else}
		<div class="relative flex min-h-0 flex-1 overflow-hidden">
			<!-- Left rail: statically positioned at md+, a slide-in drawer below md. -->
			<div
				class="fixed inset-y-0 left-0 z-50 flex transition-transform duration-200 ease-out md:static md:z-auto md:translate-x-0 md:transition-none {drawerOpen
					? 'translate-x-0'
					: '-translate-x-full'}"
				data-testid="shell-rail"
			>
				<ModeStrip />
				<NavPane />
			</div>

			<!-- Drawer backdrop (mobile only). -->
			{#if drawerOpen}
				<button
					type="button"
					class="fixed inset-0 z-40 bg-black/50 md:hidden"
					aria-label="Close navigation"
					onclick={() => (drawerOpen = false)}
				></button>
			{/if}

			<!-- Floating nav toggle (mobile only). Classic parity: it overlays the
			     top-left corner so views keep full height; each view's header pads
			     left (pl-14) on mobile to clear it. Respects the notch via safe-area. -->
			<button
				type="button"
				class="bg-background/80 hover:bg-background fixed z-30 flex size-9 items-center justify-center rounded-full border text-foreground shadow-sm backdrop-blur-sm md:hidden"
				style="top: max(0.5rem, env(safe-area-inset-top)); left: max(0.5rem, env(safe-area-inset-left));"
				aria-label="Open navigation"
				data-testid="mobile-menu"
				onclick={() => (drawerOpen = true)}
			>
				<Menu class="size-5" />
			</button>

			<div class="flex min-h-0 min-w-0 flex-1 flex-col">
				{#if workbench.tabsEnabled}
					<TabBar />
				{/if}
				<main class="min-h-0 flex-1">
					{@render children()}
				</main>
			</div>
		</div>
	{/if}
</div>

<!-- Global, app-wide overlays: branded confirm dialog + transient/undo toasts. -->
<ConfirmDialog />
<ToastHost />

<svelte:window
	onkeydown={(event) => {
		if (event.key === 'Escape') drawerOpen = false;
	}}
/>
