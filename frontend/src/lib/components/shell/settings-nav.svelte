<script lang="ts">
	import { page } from '$app/state';
	import { base } from '$app/paths';
	import {
		Boxes,
		Brain,
		Building2,
		CreditCard,
		Database,
		FolderSync,
		KeyRound,
		Key,
		Plug,
		ReceiptText,
		Server,
		Shield,
		SlidersHorizontal,
		User
	} from '@lucide/svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';

	// Settings sections, grouped by concern so the nav stays scannable as the
	// list grows. Rendered in the main nav pane (not a second sidebar).
	const groups = [
		{
			label: 'Account',
			items: [
				{ id: 'profile', label: 'Profile', icon: User },
				{ id: 'preferences', label: 'Preferences', icon: SlidersHorizontal },
				{ id: 'subscription', label: 'Subscription', icon: CreditCard },
				{ id: 'usage', label: 'Usage', icon: ReceiptText }
			]
		},
		{
			label: 'AI & Models',
			items: [
				{ id: 'models', label: 'Models', icon: Boxes },
				{ id: 'providers', label: 'Providers', icon: Key },
				{ id: 'memory', label: 'Memory', icon: Brain },
				{ id: 'mcp-servers', label: 'MCP Servers', icon: Server }
			]
		},
		{
			label: 'Workspace',
			items: [
				{ id: 'organization', label: 'Organization', icon: Building2 },
				{ id: 'integrations', label: 'Integrations', icon: Plug }
			]
		},
		{
			label: 'Storage & Data',
			items: [
				{ id: 'knowledge', label: 'File sync', icon: FolderSync },
				{ id: 'storage', label: 'Storage', icon: Database },
				{ id: 'data', label: 'Data', icon: Shield }
			]
		},
		{
			label: 'Access & Secrets',
			items: [
				{ id: 'api-tokens', label: 'API tokens', icon: KeyRound },
				{ id: 'sandbox-secrets', label: 'Sandbox secrets', icon: KeyRound }
			]
		}
	];

	// /settings/<section>[/...] → <section>; the index redirects to profile.
	const active = $derived(page.url.pathname.split('/settings/')[1]?.split('/')[0] ?? 'profile');
</script>

{#each groups as group (group.label)}
	<Sidebar.Group>
		<Sidebar.GroupLabel>{group.label}</Sidebar.GroupLabel>
		<Sidebar.GroupContent>
			<Sidebar.Menu>
				{#each group.items as section (section.id)}
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
{/each}
