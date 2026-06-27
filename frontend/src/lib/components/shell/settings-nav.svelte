<script lang="ts">
	import { page } from '$app/state';
	import { base } from '$app/paths';
	import {
		Boxes,
		CreditCard,
		Database,
		FolderSync,
		KeyRound,
		Plug,
		Server,
		Shield,
		SlidersHorizontal,
		User
	} from '@lucide/svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';

	// Settings sections, rendered in the main nav pane (not a second sidebar).
	const sections = [
		{ id: 'profile', label: 'Profile', icon: User },
		{ id: 'preferences', label: 'Preferences', icon: SlidersHorizontal },
		{ id: 'models', label: 'Models', icon: Boxes },
		{ id: 'subscription', label: 'Subscription', icon: CreditCard },
		{ id: 'integrations', label: 'Integrations', icon: Plug },
		{ id: 'knowledge', label: 'Knowledge', icon: FolderSync },
		{ id: 'mcp-servers', label: 'MCP Servers', icon: Server },
		{ id: 'storage', label: 'Storage', icon: Database },
		{ id: 'api-tokens', label: 'API tokens', icon: KeyRound },
		{ id: 'data', label: 'Data', icon: Shield }
	];

	// /settings/<section>[/...] → <section>; the index redirects to profile.
	const active = $derived(page.url.pathname.split('/settings/')[1]?.split('/')[0] ?? 'profile');
</script>

<Sidebar.Group>
	<Sidebar.GroupLabel>Settings</Sidebar.GroupLabel>
	<Sidebar.GroupContent>
		<Sidebar.Menu>
			{#each sections as section (section.id)}
				<Sidebar.MenuItem>
					<Sidebar.MenuButton isActive={active === section.id}>
						{#snippet child({ props })}
							<a
								{...props}
								href="{base}/settings/{section.id}"
								data-testid="settings-nav-{section.id}"
							>
								<section.icon class="text-muted-foreground" />
								<span>{section.label}</span>
							</a>
						{/snippet}
					</Sidebar.MenuButton>
				</Sidebar.MenuItem>
			{/each}
		</Sidebar.Menu>
	</Sidebar.GroupContent>
</Sidebar.Group>
