<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { Bot, MessageCircle, Trash2, Zap } from '@lucide/svelte';
	import MobileNavButton from '$lib/components/shell/mobile-nav-button.svelte';
	import {
		agentActivity,
		agentInboxEvents,
		agentSecrets,
		createAgentSecret,
		destroyAgentSecret,
		destroyCustomAgent,
		dismissInboxEvent,
		addAgentAttachment,
		agentAttachments,
		agentIntegrations,
		agentKnowledgeAccess,
		agentMemories,
		deleteAgentMemory,
		disconnectAgentIntegration,
		getCustomAgent,
		listAvailableSkills,
		myLibraryFiles,
		removeAgentAttachment,
		setAgentAttachmentMode,
		setAgentIntegrationTool,
		setAgentResourceAccess,
		shareAgentToTeam,
		triggerAgentRun,
		unshareAgentFromTeam,
		updateAgentMemory,
		updateCustomAgent,
		MAX_AGENT_ATTACHMENTS,
		type AgentActivityEntry,
		type AgentAttachment,
		type AgentDetail,
		type AgentIntegration,
		type AgentInboxEntry,
		type AgentKnowledgeAccess,
		type AgentMemory,
		type AttachmentMode,
		type ChatMode,
		type AgentSecretEntry,
		type AvailableSkill,
		type FileEntry,
		type ModelSummary,
		type ToolCategory
	} from '$lib/ash/api';
	import { getSocket } from '$lib/realtime/socket';
	import { relativeTime } from '$lib/time';
	import { formatFileSize } from '$lib/files/format';
	import {
		MAX_ALWAYS_INCLUDE_TOKENS,
		alwaysIncludeTokens,
		budgetTier
	} from '$lib/agents/attachment-budget';
	import AgentIntegrationWizard from '$lib/components/agents/agent-integration-wizard.svelte';
	import AgentIntegrationConfig from '$lib/components/agents/agent-integration-config.svelte';
	import { cachedActiveModels, invalidateAgentCatalog } from '$lib/chat/catalog';
	import {
		categoryEnabled,
		toggleCategory,
		toggleSkill,
		TOOL_CATEGORIES
	} from '$lib/agents/agent-tools';
	import ModelPicker from '$lib/components/chat/model-picker.svelte';
	import ProfileImagePicker from '$lib/components/settings/profile-image-picker.svelte';
	import {
		Section,
		Field,
		ToggleSwitch,
		Button,
		confirmAction,
		CONTROL_CLASS,
		TEXTAREA_CLASS
	} from '$lib/components/crud';
	import { agentsNav } from '$lib/stores/agents-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';

	const agentId = $derived(page.params.agentId!);
	const isNew = $derived(agentId === 'new');

	const SECTIONS = [
		'general',
		'tools',
		'knowledge',
		'attachments',
		'integrations',
		'privacy',
		'automation',
		'secrets',
		'activity'
	] as const;
	type Section = (typeof SECTIONS)[number];

	let agent = $state<AgentDetail | null>(null);
	let loadError = $state<string | null>(null);
	// ?section= deep links land on a specific config section (classic parity).
	const sectionParam = page.url.searchParams.get('section') as Section | null;
	let section = $state<Section>(
		sectionParam && (SECTIONS as readonly string[]).includes(sectionParam)
			? sectionParam
			: 'general'
	);
	let saving = $state(false);
	// Transient inline save feedback for the explicit-save forms (cleared on
	// section switch); persistent RPC failures also surface in the top banner.
	let saveStatus = $state<{ kind: 'ok' | 'error'; text: string } | null>(null);
	let saveError = $state<string | null>(null);
	let runMessage = $state<string | null>(null);
	let startingChat = $state(false);

	/** Viewers of shared agents inspect; only update-capable actors edit. */
	const readonly = $derived(agent !== null && !agent.editableByActor);

	async function startChat() {
		if (!agent || startingChat) return;
		startingChat = true;
		const conversation = await workbench.createConversation({ customAgentId: agent.id });
		startingChat = false;
		if (conversation) await goto(`${base}/chat/${conversation.id}`);
	}

	// The profile-image endpoint persists image_path server-side, so just
	// reflect the new URL locally and refresh the agent catalog/nav.
	function onAgentImageUpdated(url: string | null) {
		if (agent) agent = { ...agent, imageUrl: url };
		invalidateAgentCatalog();
		agentsNav.refresh();
	}

	let secrets = $state<AgentSecretEntry[]>([]);
	let activity = $state<AgentActivityEntry[]>([]);
	let inbox = $state<AgentInboxEntry[]>([]);
	let models = $state<ModelSummary[]>([]);
	let availableSkills = $state<AvailableSkill[]>([]);

	// Local drafts for the explicit-save form fields (text / number). Toggles,
	// selects, and model pickers still apply immediately. Seeded when a different
	// agent loads; a Save sends the draft and re-syncs `agent`, so `*Dirty` falls
	// back to false. Switching sections keeps unsaved drafts (no data loss).
	let gName = $state('');
	let gDescription = $state('');
	let gIcon = $state('');
	let gInstructions = $state('');
	let gMaxIterations = $state(10);
	let gHeartbeatInterval = $state(60);
	let gHeartbeatInstructions = $state('');
	let gMaxDailyRuns = $state(24);

	const generalDirty = $derived(
		!!agent &&
			(gName !== agent.name ||
				gDescription !== (agent.description ?? '') ||
				gIcon !== (agent.icon ?? '') ||
				gInstructions !== (agent.instructions ?? ''))
	);
	const toolsDirty = $derived(!!agent && gMaxIterations !== (agent.maxIterations ?? 10));
	const automationDirty = $derived(
		!!agent &&
			(gHeartbeatInterval !== (agent.heartbeatDefaultIntervalMinutes ?? 60) ||
				gHeartbeatInstructions !== (agent.heartbeatInstructions ?? '') ||
				gMaxDailyRuns !== (agent.maxDailyRuns ?? 24))
	);

	// Optimistic local copies of the two ARRAY fields: each toggle row writes the
	// same field, so reading the post-RPC `agent.*` snapshot per toggle would let
	// rapid toggles clobber each other. Seeded when a different agent loads;
	// mutated synchronously on toggle and sent as-is.
	let seededId: string | null = null;
	let disabledCats = $state<ToolCategory[]>([]);
	let preSkills = $state<string[]>([]);
	$effect(() => {
		const a = agent;
		if (a && a.id !== seededId) {
			seededId = a.id;
			disabledCats = [...a.disabledToolCategories];
			preSkills = [...a.preLoadedSkills];
			gName = a.name;
			gDescription = a.description ?? '';
			gIcon = a.icon ?? '';
			gInstructions = a.instructions ?? '';
			gMaxIterations = a.maxIterations ?? 10;
			gHeartbeatInterval = a.heartbeatDefaultIntervalMinutes ?? 60;
			gHeartbeatInstructions = a.heartbeatInstructions ?? '';
			gMaxDailyRuns = a.maxDailyRuns ?? 24;
		}
	});

	function setCategory(key: ToolCategory, enabled: boolean) {
		disabledCats = toggleCategory(disabledCats, key, enabled);
		void patch({ disabledToolCategories: disabledCats });
	}
	function setSkill(name: string, on: boolean) {
		preSkills = toggleSkill(preSkills, name, on);
		void patch({ preLoadedSkills: preSkills });
	}

	// Knowledge section: agent memories + brain / collection grants.
	const MEMORY_KINDS = [
		'general',
		'fact',
		'hypothesis',
		'observation',
		'summary',
		'preference',
		'goal',
		'topic',
		'habit',
		'reflection'
	];
	let memories = $state<AgentMemory[]>([]);
	let knowledgeAccess = $state<AgentKnowledgeAccess | null>(null);
	let selectedMemory = $state<AgentMemory | null>(null);

	// Edit form, seeded whenever a memory is opened.
	let editSummary = $state('');
	let editKind = $state('general');
	let editConfidence = $state(100);
	$effect(() => {
		const m = selectedMemory;
		if (m) {
			editSummary = m.summary ?? '';
			editKind = m.kind;
			editConfidence = Math.round(m.confidence * 100);
		}
	});

	function loadKnowledge(id: string) {
		void agentMemories(id).then((result) => {
			if (id === agentId && result.success) memories = result.data;
		});
		void agentKnowledgeAccess(id).then((result) => {
			if (id === agentId && result.success) knowledgeAccess = result.data;
		});
	}

	async function saveMemory(summary: string, kind: string, confidence: number) {
		if (!selectedMemory) return;
		const result = await updateAgentMemory({
			memoryId: selectedMemory.id,
			summary: summary.trim() || null,
			kind,
			confidence
		});
		if (result.success) {
			selectedMemory = result.data;
			memories = memories.map((m) => (m.id === result.data.id ? result.data : m));
			saveStatus = { kind: 'ok', text: 'Saved' };
		}
	}

	async function removeMemory() {
		if (!selectedMemory) return;
		const ok = await confirmAction({
			title: 'Delete this memory?',
			description: `"${selectedMemory.name}" will be permanently removed.`,
			confirmLabel: 'Delete'
		});
		if (!ok) return;
		const id = selectedMemory.id;
		const result = await deleteAgentMemory(id);
		if (result.success) {
			memories = memories.filter((m) => m.id !== id);
			selectedMemory = null;
		}
	}

	// Per-resource grant toggle — each targets a distinct brain/collection, so a
	// local optimistic flip is safe (no shared-array clobber). On failure the
	// flip is reverted by re-loading from the server and the error surfaced.
	async function setBrainAccess(brainId: string, granted: boolean) {
		if (!knowledgeAccess) return;
		knowledgeAccess = {
			...knowledgeAccess,
			brains: knowledgeAccess.brains.map((b) => (b.id === brainId ? { ...b, granted } : b))
		};
		const result = await setAgentResourceAccess({
			agentId,
			resourceType: 'brain',
			resourceId: brainId,
			granted
		});
		if (!result.success) {
			saveError = result.errors[0]?.message ?? 'Could not change brain access';
			loadKnowledge(agentId);
		}
	}

	async function setCollectionAccess(collectionId: string, granted: boolean) {
		if (!knowledgeAccess) return;
		knowledgeAccess = {
			...knowledgeAccess,
			sources: knowledgeAccess.sources.map((source) => ({
				...source,
				collections: source.collections.map((c) => (c.id === collectionId ? { ...c, granted } : c))
			}))
		};
		const result = await setAgentResourceAccess({
			agentId,
			resourceType: 'knowledge_collection',
			resourceId: collectionId,
			granted
		});
		if (!result.success) {
			saveError = result.errors[0]?.message ?? 'Could not change collection access';
			loadKnowledge(agentId);
		}
	}

	// Attachments section: agent reference files (always-include / search).
	let attachments = $state<AgentAttachment[]>([]);
	let libraryFiles = $state<FileEntry[]>([]);
	let pickerOpen = $state(false);
	const attachedFileIds = $derived(new Set(attachments.map((a) => a.fileId)));
	// Only text-bearing files make sense as agent reference docs (RAG /
	// always-include); images/video/audio are filtered out of the picker.
	const ATTACHABLE_TYPES = new Set(['document', 'text', 'email']);
	const pickableFiles = $derived(
		libraryFiles.filter((file) => ATTACHABLE_TYPES.has(file.type) && !attachedFileIds.has(file.id))
	);
	// Always-include files are injected into every prompt, so their combined
	// token_count is budgeted against AttachmentLimits.max_always_include_tokens.
	const alwaysTokens = $derived(alwaysIncludeTokens(attachments));
	const tokenTier = $derived(budgetTier(alwaysTokens));

	function loadAttachments(id: string) {
		void agentAttachments(id).then((result) => {
			if (id === agentId && result.success) attachments = result.data;
		});
	}

	function openFilePicker() {
		pickerOpen = !pickerOpen;
		if (pickerOpen && libraryFiles.length === 0) {
			void myLibraryFiles().then((result) => {
				if (result.success) libraryFiles = result.data;
			});
		}
	}

	async function addAttachment(fileId: string) {
		const result = await addAgentAttachment(agentId, fileId, 'search');
		if (result.success) {
			pickerOpen = false;
			loadAttachments(agentId);
		} else {
			saveError = result.errors[0]?.message ?? 'Could not attach file';
		}
	}

	async function setAttachmentMode(attachmentId: string, mode: AttachmentMode) {
		attachments = attachments.map((a) => (a.id === attachmentId ? { ...a, mode } : a));
		const result = await setAgentAttachmentMode(attachmentId, mode);
		if (!result.success) {
			saveError = result.errors[0]?.message ?? 'Could not change mode';
			loadAttachments(agentId);
		}
	}

	async function removeAttachment(attachmentId: string) {
		attachments = attachments.filter((a) => a.id !== attachmentId);
		await removeAgentAttachment(attachmentId);
	}

	// Integrations section (manage-only): list / disconnect / tool toggle.
	let integrations = $state<AgentIntegration[]>([]);
	let integrationsLoaded = $state(false);
	let integrationWizardOpen = $state(false);

	function loadIntegrations(id: string) {
		integrationsLoaded = false;
		void agentIntegrations(id).then((result) => {
			if (id !== agentId) return;
			if (result.success) integrations = result.data;
			integrationsLoaded = true;
		});
	}

	async function disconnectIntegration(integrationId: string, providerName: string) {
		const ok = await confirmAction({
			title: `Disconnect ${providerName}?`,
			description: 'The agent will lose access to this integration’s tools.',
			confirmLabel: 'Disconnect'
		});
		if (!ok) return;
		integrations = integrations.filter((i) => i.id !== integrationId);
		const result = await disconnectAgentIntegration(integrationId);
		if (!result.success) {
			saveError = result.errors[0]?.message ?? 'Could not disconnect';
			loadIntegrations(agentId);
		}
	}

	async function setIntegrationTool(integrationId: string, tool: string, enabled: boolean) {
		integrations = integrations.map((i) =>
			i.id === integrationId
				? {
						...i,
						enabledTools: enabled
							? [...new Set([...i.enabledTools, tool])]
							: i.enabledTools.filter((t) => t !== tool)
					}
				: i
		);
		const result = await setAgentIntegrationTool(integrationId, tool, enabled);
		if (result.success) {
			integrations = integrations.map((i) =>
				i.id === integrationId ? { ...i, enabledTools: result.data.enabledTools } : i
			);
		} else {
			saveError = result.errors[0]?.message ?? 'Could not update tool';
			loadIntegrations(agentId);
		}
	}

	// New-secret form.
	let secretKey = $state('');
	let secretValue = $state('');

	// One-shot: deep links sync the nav once; afterwards the mode strip
	// may switch the nav freely without this route forcing it back.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'agents') void workbench.setMode('agents');
	});

	let previousAgentId: string | null = null;
	$effect(() => {
		const id = agentId;
		agent = null;
		loadError = null;
		// Honor the ?section= deep link on first load; only reset to the default
		// section when actually switching to a different agent.
		if (previousAgentId !== null && previousAgentId !== id) section = 'general';
		previousAgentId = id;
		runMessage = null;
		saveStatus = null;
		// Creation lives in the shared "New agent" dialog; this route only edits.
		if (id === 'new') {
			void goto(`${base}/agents`, { replaceState: true });
			return;
		}

		void getCustomAgent(id).then((result) => {
			if (id !== agentId) return;
			if (result.success) agent = result.data;
			else loadError = result.errors[0]?.message ?? 'Agent could not be loaded';
		});
	});

	// Section data loads lazily; the agent channel refreshes activity/inbox.
	$effect(() => {
		const id = agentId;
		saveStatus = null;
		if (id === 'new') return;
		if (section === 'tools') {
			if (models.length === 0) {
				void cachedActiveModels().then((result) => {
					if (result.success) models = result.data;
				});
			}
			if (availableSkills.length === 0) {
				void listAvailableSkills().then((result) => {
					if (result.success) availableSkills = result.data;
				});
			}
		}
		if (section === 'knowledge') {
			selectedMemory = null;
			loadKnowledge(id);
		}
		if (section === 'attachments') {
			pickerOpen = false;
			loadAttachments(id);
		}
		if (section === 'integrations') {
			loadIntegrations(id);
		}
		if (section === 'secrets') {
			void agentSecrets(id).then((result) => {
				if (id === agentId && result.success) secrets = result.data;
			});
		}
		if (section === 'activity') {
			void agentActivity(id).then((result) => {
				if (id === agentId && result.success) activity = result.data;
			});
			void agentInboxEvents(id).then((result) => {
				if (id === agentId && result.success) inbox = result.data;
			});
		}
	});

	// agent:<id> channel: live activity + inbox refresh hints.
	$effect(() => {
		const id = agentId;
		if (id === 'new') return;

		let cancelled = false;
		let leave: (() => void) | null = null;

		void getSocket().then((socket) => {
			if (!socket || cancelled) return;
			const channel = socket.channel(`agent:${id}`);

			channel.on('activity.new', () => {
				void agentActivity(id).then((result) => {
					if (id === agentId && result.success) activity = result.data;
				});
			});
			channel.on('activity.inbox_changed', () => {
				void agentInboxEvents(id).then((result) => {
					if (id === agentId && result.success) inbox = result.data;
				});
			});

			channel.join();
			leave = () => channel.leave();
		});

		return () => {
			cancelled = true;
			leave?.();
		};
	});

	/**
	 * Immediate partial save for toggles / selects / model pickers. Each carries
	 * only its own field, so overlapping saves don't clobber each other. The two
	 * ARRAY fields (disabledToolCategories / preLoadedSkills) go through optimistic
	 * local copies (setCategory/setSkill) to avoid stale-snapshot lost updates.
	 * Text / number fields use the explicit-save forms (`saveSection`) instead.
	 */
	async function patch(input: Parameters<typeof updateCustomAgent>[1]): Promise<boolean> {
		if (!agent) return false;
		saving = true;
		saveError = null;
		const result = await updateCustomAgent(agent.id, input);
		saving = false;
		if (result.success) {
			agent = result.data;
			agentsNav.refresh();
			invalidateAgentCatalog();
			return true;
		}
		// Workspace viewers can open shared agents but not edit them — the
		// server's denial must be visible, not silently swallowed.
		saveError = result.errors[0]?.message ?? 'Change could not be saved';
		return false;
	}

	/** Explicit-save for a section's text/number fields (dirty-gated Save button). */
	async function saveSection(input: Parameters<typeof updateCustomAgent>[1]) {
		if (!agent || saving) return;
		saving = true;
		saveStatus = null;
		const result = await updateCustomAgent(agent.id, input);
		saving = false;
		if (result.success) {
			agent = result.data;
			agentsNav.refresh();
			invalidateAgentCatalog();
			saveStatus = { kind: 'ok', text: 'Saved' };
		} else {
			saveStatus = { kind: 'error', text: result.errors[0]?.message ?? 'Could not save' };
		}
	}

	const saveGeneral = () =>
		void saveSection({
			name: gName.trim(),
			description: gDescription.trim() || null,
			icon: gIcon.trim() || null,
			instructions: gInstructions.trim() || null
		});
	const saveTools = () => void saveSection({ maxIterations: gMaxIterations || 10 });
	const saveAutomation = () =>
		void saveSection({
			heartbeatDefaultIntervalMinutes: gHeartbeatInterval || 60,
			heartbeatInstructions: gHeartbeatInstructions.trim() || null,
			maxDailyRuns: gMaxDailyRuns || 24
		});

	function resetGeneral() {
		if (!agent) return;
		gName = agent.name;
		gDescription = agent.description ?? '';
		gIcon = agent.icon ?? '';
		gInstructions = agent.instructions ?? '';
		saveStatus = null;
	}
	function resetTools() {
		if (!agent) return;
		gMaxIterations = agent.maxIterations ?? 10;
		saveStatus = null;
	}
	function resetAutomation() {
		if (!agent) return;
		gHeartbeatInterval = agent.heartbeatDefaultIntervalMinutes ?? 60;
		gHeartbeatInstructions = agent.heartbeatInstructions ?? '';
		gMaxDailyRuns = agent.maxDailyRuns ?? 24;
		saveStatus = null;
	}

	async function remove() {
		if (!agent) return;
		const ok = await confirmAction({
			title: `Delete ${agent.name}?`,
			description: 'This permanently deletes the agent and all of its configuration.',
			confirmLabel: 'Delete agent'
		});
		if (!ok) return;
		const result = await destroyCustomAgent(agent.id);
		if (result.success) {
			agentsNav.refresh();
			invalidateAgentCatalog();
			await goto(`${base}/agents`);
		} else {
			saveError = result.errors[0]?.message ?? 'Could not delete agent';
		}
	}

	async function toggleShare() {
		if (!agent) return;
		const result = agent.isSharedToWorkspace
			? await unshareAgentFromTeam(agent.id)
			: await shareAgentToTeam(agent.id);
		if (result.success) {
			agent = result.data;
			agentsNav.refresh();
		}
	}

	async function runNow() {
		if (!agent) return;
		runMessage = null;
		const result = await triggerAgentRun(agent.id);
		runMessage = result.success ? 'Run started.' : (result.errors[0]?.message ?? 'Run failed');
	}

	async function addSecret() {
		if (!agent || !secretKey.trim() || !secretValue) return;
		const result = await createAgentSecret({
			customAgentId: agent.id,
			key: secretKey.trim(),
			value: secretValue
		});
		if (result.success) {
			secrets = [...secrets, result.data];
			secretKey = '';
			secretValue = '';
		}
	}

	async function removeSecret(id: string, key: string) {
		const ok = await confirmAction({
			title: `Delete secret ${key}?`,
			description: 'The agent will no longer have access to this value.',
			confirmLabel: 'Delete'
		});
		if (!ok) return;
		const result = await destroyAgentSecret(id);
		if (result.success) secrets = secrets.filter((secret) => secret.id !== id);
	}

	async function dismiss(event: AgentInboxEntry) {
		const result = await dismissInboxEvent(event.id);
		if (result.success) {
			inbox = inbox.map((entry) => (entry.id === event.id ? result.data : entry));
		}
	}
</script>

<svelte:head>
	<title>Magus — {isNew ? 'New agent' : (agent?.name ?? 'Agent')}</title>
</svelte:head>

{#snippet toggleRow(label: string, value: boolean, onchange: (next: boolean) => void)}
	<div class="flex items-center justify-between gap-4 py-2 text-sm">
		<span>{label}</span>
		<ToggleSwitch checked={value} {onchange} {label} />
	</div>
{/snippet}

{#snippet saveBar(dirty: boolean, onsave: () => void, oncancel: () => void)}
	<div class="flex items-center gap-3 pt-1">
		<Button onclick={onsave} disabled={!dirty || saving}>{saving ? 'Saving…' : 'Save'}</Button>
		{#if dirty}
			<Button variant="ghost" onclick={oncancel} disabled={saving}>Cancel</Button>
		{/if}
		{#if saveStatus}
			<span
				class="text-xs {saveStatus.kind === 'ok' ? 'text-muted-foreground' : 'text-destructive'}"
			>
				{saveStatus.text}
			</span>
		{/if}
	</div>
{/snippet}

<div class="flex h-full min-h-0 flex-col" data-testid="agent-detail">
	{#if loadError}
		<p class="p-6 text-sm text-destructive">{loadError}</p>
	{:else if !agent}
		<div class="space-y-3 p-6">
			<div class="h-5 w-1/3 animate-pulse rounded bg-muted"></div>
			<div class="h-40 animate-pulse rounded-xl bg-muted"></div>
		</div>
	{:else}
		<header class="flex min-h-11 shrink-0 items-center gap-2 border-b py-2 px-6">
			<MobileNavButton />
			{#if agent.imageUrl}
				<img
					src={agent.imageUrl}
					alt={agent.name}
					class="size-6 shrink-0 rounded-full border border-input object-cover"
					data-testid="agent-avatar"
				/>
			{:else}
				<span
					class="flex size-6 shrink-0 items-center justify-center rounded-full border border-input bg-secondary text-xs"
				>
					{#if agent.icon}{agent.icon}{:else}<Bot class="size-3.5 text-muted-foreground" />{/if}
				</span>
			{/if}
			<div class="flex min-w-0 flex-1 items-baseline gap-2">
				<h1 class="min-w-0 truncate text-sm font-semibold" data-testid="agent-title">
					{agent.name}
				</h1>
				<p class="min-w-0 truncate text-xs text-muted-foreground max-md:hidden">
					@{agent.handle}
					{#if agent.isPaused}· paused{/if}
					{#if agent.isSharedToWorkspace}· workspace{/if}
					{#if readonly}· view only{/if}
				</p>
			</div>
			<button
				type="button"
				class="wb-pill-btn shrink-0"
				data-testid="agent-start-chat"
				disabled={startingChat}
				onclick={() => void startChat()}
			>
				<MessageCircle class="size-3.5" />
				<span>Start chat</span>
			</button>
			{#if !readonly}
				<button
					type="button"
					class="wb-pill-btn shrink-0"
					data-testid="agent-run-now"
					title="Run this agent's task once, right now"
					onclick={() => void runNow()}
				>
					<Zap class="size-3.5" />
					<span>Run now</span>
				</button>
				{#if session.user?.currentWorkspaceId}
					<button type="button" class="wb-pill-btn shrink-0" onclick={() => void toggleShare()}>
						{agent.isSharedToWorkspace ? 'Unshare' : 'Share'}
					</button>
				{/if}
				<button
					type="button"
					class="wb-pill-btn wb-pill-btn-square shrink-0"
					aria-label="Delete agent"
					data-testid="agent-delete"
					onclick={() => void remove()}
				>
					<Trash2 class="size-3.5" />
				</button>
			{/if}
		</header>

		{#if runMessage}
			<p class="border-b bg-secondary/50 px-6 py-1.5 text-xs text-secondary-foreground">
				{runMessage}
			</p>
		{/if}
		{#if saveError}
			<p
				class="border-b bg-destructive/10 px-6 py-1.5 text-xs text-destructive"
				data-testid="agent-save-error"
			>
				{saveError}
			</p>
		{/if}

		<nav
			class="wb-scroll flex shrink-0 items-center gap-1.5 overflow-x-auto border-b px-4 py-2"
			data-testid="agent-sections"
		>
			{#each SECTIONS as entry (entry)}
				<button
					type="button"
					class="rounded-full px-3 py-1 text-sm capitalize whitespace-nowrap transition-colors {section ===
					entry
						? 'bg-secondary font-medium text-foreground'
						: 'text-muted-foreground hover:bg-accent/40 hover:text-foreground'}"
					data-testid="agent-section-{entry}"
					onclick={() => (section = entry)}
				>
					{entry}
				</button>
			{/each}
		</nav>

		<!-- fieldset[disabled] inertly disables every nested input/button, so
		     shared-agent viewers inspect without auto-save failure banners.
		     min-w-0 overrides the UA's fieldset min-inline-size: min-content,
		     which otherwise lets one unbreakable line stretch past max-w-2xl. -->
		<fieldset
			disabled={readonly}
			class="wb-scroll mx-auto block w-full max-w-2xl min-w-0 min-h-0 flex-1 space-y-4 overflow-y-auto p-6"
		>
			{#if section === 'general'}
				<Section title="Profile" description="How this agent is identified across Magus.">
					<div class="flex flex-col gap-4">
						{#if !readonly}
							<div class="flex flex-col gap-1.5">
								<span class="text-xs font-medium text-muted-foreground">Image</span>
								<ProfileImagePicker
									target={{ kind: 'agent', agentId: agent.id }}
									currentUrl={agent.imageUrl}
									onUpdated={onAgentImageUpdated}
								/>
							</div>
						{/if}
						<Field label="Name">
							<input bind:value={gName} class={CONTROL_CLASS} data-testid="agent-name-input" />
						</Field>
						<Field label="Description">
							<input bind:value={gDescription} class={CONTROL_CLASS} />
						</Field>
						<Field
							label="Icon"
							hint="A single emoji, shown in lists and menus when no image is set."
						>
							<input
								bind:value={gIcon}
								maxlength="8"
								class="{CONTROL_CLASS} w-24"
								data-testid="agent-icon-input"
							/>
						</Field>
						<Field label="Instructions" hint="What this agent should do and how it should behave.">
							<textarea
								bind:value={gInstructions}
								rows="10"
								data-testid="agent-instructions"
								class={TEXTAREA_CLASS}
							></textarea>
						</Field>
						{@render saveBar(generalDirty, saveGeneral, resetGeneral)}
					</div>
				</Section>
			{:else if section === 'tools'}
				<Section title="Limits" description="How the agent runs its tool loop.">
					<div class="flex flex-col gap-4">
						<Field label="Max iterations" hint="Most tool calls the agent may chain in one turn.">
							<input
								type="number"
								min="1"
								bind:value={gMaxIterations}
								class="{CONTROL_CLASS} w-32"
							/>
						</Field>
						<Field label="Default mode">
							<select
								value={agent.chatMode ?? 'chat'}
								class="{CONTROL_CLASS} w-48"
								onchange={(event) =>
									void patch({ chatMode: event.currentTarget.value as ChatMode })}
							>
								<option value="chat">Chat</option>
								<option value="search">Search</option>
								<option value="reasoning">Reasoning</option>
								<option value="image_generation">Image generation</option>
								<option value="video_generation">Video generation</option>
							</select>
						</Field>
						{@render saveBar(toolsDirty, saveTools, resetTools)}
					</div>
				</Section>

				<Section
					title="Model presets"
					description="Default models for chat, image, and video (Auto lets the router pick)."
				>
					<div class="flex flex-col gap-2 text-sm">
						<div class="flex items-center justify-between gap-4">
							<span class="text-muted-foreground">Chat</span>
							<ModelPicker
								{models}
								chatMode="chat"
								selectedModelId={agent.modelId}
								onPick={(id) => void patch({ modelId: id })}
							/>
						</div>
						<div class="flex items-center justify-between gap-4">
							<span class="text-muted-foreground">Image</span>
							<ModelPicker
								{models}
								chatMode="image_generation"
								selectedModelId={agent.imageModelId}
								onPick={(id) => void patch({ imageModelId: id })}
							/>
						</div>
						<div class="flex items-center justify-between gap-4">
							<span class="text-muted-foreground">Video</span>
							<ModelPicker
								{models}
								chatMode="video_generation"
								selectedModelId={agent.videoModelId}
								onPick={(id) => void patch({ videoModelId: id })}
							/>
						</div>
					</div>
				</Section>

				<Section
					title="Tool categories"
					description="Turn off categories this agent shouldn't use."
				>
					<div class="flex flex-col divide-y divide-border" data-testid="tool-categories">
						{#each TOOL_CATEGORIES as category (category.key)}
							{@render toggleRow(
								category.label,
								categoryEnabled(disabledCats, category.key),
								(next) => setCategory(category.key, next)
							)}
						{/each}
					</div>
				</Section>

				<Section
					title="Pre-loaded skills"
					description="Skills loaded into every conversation with this agent."
				>
					{#if availableSkills.length === 0}
						<p class="text-xs text-muted-foreground">No skills available.</p>
					{:else}
						<div class="flex flex-col divide-y divide-border" data-testid="preloaded-skills">
							{#each availableSkills as skill (skill.name)}
								<div class="flex items-start justify-between gap-4 py-2">
									<span class="min-w-0">
										<span class="block text-sm font-medium">{skill.name}</span>
										{#if skill.description}
											<span class="block text-xs text-muted-foreground">{skill.description}</span>
										{/if}
									</span>
									<ToggleSwitch
										checked={preSkills.includes(skill.name)}
										label={skill.name}
										onchange={(next) => setSkill(skill.name, next)}
									/>
								</div>
							{/each}
						</div>
					{/if}
				</Section>
			{:else if section === 'knowledge'}
				{#if selectedMemory}
					<!-- Memory detail / edit. -->
					<Section title={selectedMemory.name} description="Edit or remove this memory.">
						<div class="flex flex-col gap-4">
							<button
								type="button"
								class="self-start rounded-md px-2 py-1 text-sm text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
								onclick={() => (selectedMemory = null)}
							>
								← Back to memories
							</button>
							<Field label="Summary">
								<textarea bind:value={editSummary} rows="4" class={TEXTAREA_CLASS}></textarea>
							</Field>
							<Field label="Kind">
								<select bind:value={editKind} class="{CONTROL_CLASS} w-48 capitalize">
									{#each MEMORY_KINDS as kind (kind)}
										<option value={kind} class="capitalize">{kind}</option>
									{/each}
								</select>
							</Field>
							<Field label="Confidence: {editConfidence}%">
								<input type="range" min="0" max="100" bind:value={editConfidence} class="w-64" />
							</Field>
							<div class="flex items-center gap-3 pt-1">
								<Button
									onclick={() => void saveMemory(editSummary, editKind, editConfidence / 100)}
								>
									Save changes
								</Button>
								<Button
									variant="destructive"
									data-testid="delete-memory"
									onclick={() => void removeMemory()}
								>
									Delete
								</Button>
								{#if saveStatus}
									<span
										class="text-xs {saveStatus.kind === 'ok'
											? 'text-muted-foreground'
											: 'text-destructive'}"
									>
										{saveStatus.text}
									</span>
								{/if}
							</div>
						</div>
					</Section>
				{:else}
					<Section
						title="Memory"
						description="Memories the agent builds over time. Select one to view, edit, or remove it."
					>
						{#if memories.length === 0}
							<p class="text-xs text-muted-foreground">
								No memories yet — the agent creates them automatically during conversations.
							</p>
						{:else}
							<div class="flex flex-col gap-1.5" data-testid="agent-memories">
								{#each memories as memory (memory.id)}
									<button
										type="button"
										class="flex items-start justify-between gap-2 rounded-lg bg-secondary/60 px-3 py-2 text-left transition-colors hover:bg-accent/60"
										onclick={() => (selectedMemory = memory)}
									>
										<span class="min-w-0">
											<span class="flex items-center gap-2">
												<span class="text-sm font-medium">{memory.name}</span>
												{#if memory.kind !== 'general'}
													<span
														class="rounded border border-input px-1.5 text-[11px] text-muted-foreground capitalize"
													>
														{memory.kind}
													</span>
												{/if}
											</span>
											{#if memory.summary}
												<span class="mt-0.5 block truncate text-xs text-muted-foreground">
													{memory.summary}
												</span>
											{/if}
										</span>
										<span class="shrink-0 text-xs text-muted-foreground">
											{Math.round(memory.confidence * 100)}%
										</span>
									</button>
								{/each}
							</div>
						{/if}
					</Section>

					<Section
						title="Knowledge access"
						description="Let this agent search the collections granted below."
					>
						<div class="divide-y divide-border">
							{@render toggleRow(
								'Enable knowledge search',
								agent.canAccessKnowledge,
								(next) => void patch({ canAccessKnowledge: next })
							)}
						</div>
					</Section>

					<Section
						title="Brain access"
						description="Brains this agent can read and edit autonomously."
					>
						{#if !knowledgeAccess || knowledgeAccess.brains.length === 0}
							<p class="text-xs text-muted-foreground">No brains created yet.</p>
						{:else}
							<div class="flex flex-col divide-y divide-border" data-testid="agent-brains">
								{#each knowledgeAccess.brains as brain (brain.id)}
									<div class="flex items-center justify-between gap-4 py-2 text-sm">
										<span class="min-w-0 truncate">{brain.icon ?? '🧠'} {brain.title}</span>
										<ToggleSwitch
											checked={brain.granted}
											label={brain.title}
											onchange={(next) => void setBrainAccess(brain.id, next)}
										/>
									</div>
								{/each}
							</div>
						{/if}
					</Section>

					<Section title="Collections" description="Knowledge collections this agent can search.">
						{#if !knowledgeAccess || knowledgeAccess.sources.length === 0}
							<p class="text-xs text-muted-foreground">
								No knowledge sources connected.
								<a
									href="{base}/settings/knowledge"
									class="text-foreground underline-offset-2 hover:underline"
									data-testid="agent-connect-knowledge-link"
								>
									Connect a source
								</a>
							</p>
						{:else}
							<div class="flex flex-col gap-3" data-testid="agent-collections">
								{#each knowledgeAccess.sources as source (source.name)}
									<div class="flex flex-col">
										<span class="mb-1 text-xs tracking-wider text-muted-foreground uppercase">
											{source.name}
										</span>
										<div class="flex flex-col divide-y divide-border">
											{#each source.collections as collection (collection.id)}
												<div class="flex items-center justify-between gap-3 py-2 text-sm">
													<span class="min-w-0 flex-1 truncate">{collection.name}</span>
													<span class="text-xs text-muted-foreground">{collection.itemCount}</span>
													<ToggleSwitch
														checked={collection.granted}
														label={collection.name}
														onchange={(next) => void setCollectionAccess(collection.id, next)}
													/>
												</div>
											{/each}
										</div>
									</div>
								{/each}
							</div>
						{/if}
					</Section>
				{/if}
			{:else if section === 'attachments'}
				<Section
					title="Reference files"
					description="Always-include files go in the prompt; search files are retrieved on demand."
				>
					{#snippet actions()}
						<span class="text-xs text-muted-foreground" data-testid="attachment-count">
							{attachments.length}/{MAX_AGENT_ATTACHMENTS}
						</span>
					{/snippet}

					{#if attachments.length > 0}
						<div class="flex flex-col divide-y divide-border" data-testid="agent-attachments">
							{#each attachments as attachment (attachment.id)}
								<div class="flex items-center gap-3 py-2 text-sm">
									<span class="min-w-0 flex-1">
										<span class="block truncate font-medium">{attachment.fileName}</span>
										{#if attachment.fileSize || attachment.status !== 'ready'}
											<span class="block text-xs text-muted-foreground">
												{#if attachment.fileSize}{formatFileSize(attachment.fileSize)}{/if}
												{#if attachment.status !== 'ready'}<span
														class={attachment.status === 'error'
															? 'text-destructive'
															: 'text-warning'}
														data-testid="attachment-file-status">· {attachment.status}</span
													>{/if}
											</span>
										{/if}
									</span>
									<select
										value={attachment.mode}
										disabled={attachment.status !== 'ready'}
										title={attachment.status !== 'ready'
											? 'Available once the file finishes processing'
											: undefined}
										class="rounded-md border border-input bg-secondary px-2 py-1 text-xs outline-none focus:border-primary/60 disabled:cursor-not-allowed disabled:opacity-50"
										onchange={(event) =>
											void setAttachmentMode(
												attachment.id,
												event.currentTarget.value as AttachmentMode
											)}
									>
										<option value="always">Always include</option>
										<option value="search">Search</option>
									</select>
									<button
										type="button"
										class="rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-destructive"
										aria-label="Remove attachment"
										data-testid="remove-attachment"
										onclick={() => void removeAttachment(attachment.id)}
									>
										<Trash2 class="size-4" />
									</button>
								</div>
							{/each}
						</div>
						{#if attachments.some((a) => a.mode === 'always')}
							<p
								class="mt-3 text-xs {tokenTier === 'over'
									? 'font-semibold text-destructive'
									: tokenTier === 'warn'
										? 'font-semibold text-warning'
										: 'text-muted-foreground'}"
								data-testid="attachment-token-budget"
							>
								Always-include tokens: {alwaysTokens.toLocaleString()} / {MAX_ALWAYS_INCLUDE_TOKENS.toLocaleString()}
								{#if tokenTier === 'over'}
									— over budget, trim always-include files{/if}
							</p>
						{/if}
					{:else}
						<p class="text-xs text-muted-foreground">No files attached yet.</p>
					{/if}

					{#if attachments.length < MAX_AGENT_ATTACHMENTS}
						<div class="mt-3 flex flex-col gap-2">
							<Button variant="outline" size="sm" class="w-fit" onclick={openFilePicker}>
								{pickerOpen ? 'Cancel' : '+ Attach a file'}
							</Button>
							{#if pickerOpen}
								<div
									class="max-h-64 overflow-y-auto rounded-lg border border-input"
									data-testid="file-picker"
								>
									{#each pickableFiles as file (file.id)}
										<button
											type="button"
											class="flex w-full items-center justify-between gap-2 px-3 py-2 text-left text-sm hover:bg-accent/60"
											onclick={() => void addAttachment(file.id)}
										>
											<span class="min-w-0 truncate">{file.name}</span>
											{#if file.fileSize}
												<span class="shrink-0 text-xs text-muted-foreground">
													{formatFileSize(file.fileSize)}
												</span>
											{/if}
										</button>
									{:else}
										<p class="px-3 py-2 text-xs text-muted-foreground">No files in your library.</p>
									{/each}
								</div>
							{/if}
						</div>
					{/if}
				</Section>
			{:else if section === 'integrations'}
				<Section
					title="Integrations"
					description="Connect channels, calendars, and data sources for this agent."
				>
					{#snippet actions()}
						<Button
							size="sm"
							variant="outline"
							onclick={() => (integrationWizardOpen = true)}
							data-testid="agent-integration-connect"
						>
							+ Connect new
						</Button>
					{/snippet}

					{#if !integrationsLoaded}
						<div class="h-16 animate-pulse rounded-lg bg-muted/60"></div>
					{:else if integrations.length === 0}
						<p class="text-sm text-muted-foreground">No integrations connected.</p>
					{:else}
						<div class="flex flex-col gap-3" data-testid="agent-integrations">
							{#each integrations as integration (integration.id)}
								<div class="rounded-lg border border-input p-3">
									<div class="flex items-center justify-between gap-2">
										<div class="min-w-0">
											<span class="block truncate text-sm font-medium">
												{integration.providerName}
											</span>
											<span class="text-xs text-muted-foreground capitalize">
												{integration.sourceType} · {integration.status}
											</span>
										</div>
										<Button
											variant="destructive"
											size="sm"
											data-testid="disconnect-integration"
											onclick={() =>
												void disconnectIntegration(integration.id, integration.providerName)}
										>
											Disconnect
										</Button>
									</div>
									{#if integration.availableTools.length > 0}
										<div
											class="mt-2 flex flex-col divide-y divide-border border-t border-input pt-2"
										>
											<span class="pb-1 text-[10px] tracking-wider text-muted-foreground uppercase">
												Tools
											</span>
											{#each integration.availableTools as tool (tool.key)}
												<div class="flex items-center justify-between gap-4 py-1.5 text-sm">
													<span>{tool.name}</span>
													<ToggleSwitch
														checked={integration.enabledTools.includes(tool.key)}
														label={tool.name}
														onchange={(next) =>
															void setIntegrationTool(integration.id, tool.key, next)}
													/>
												</div>
											{/each}
										</div>
									{/if}

									<AgentIntegrationConfig {integration} onSaved={() => loadIntegrations(agentId)} />
								</div>
							{/each}
						</div>
					{/if}

					<AgentIntegrationWizard
						bind:open={integrationWizardOpen}
						{agentId}
						connectedKeys={integrations.map((i) => i.providerKey)}
						onConnected={() => loadIntegrations(agentId)}
					/>
				</Section>
			{:else if section === 'privacy'}
				<Section
					title="Privacy"
					description="What this agent may read and write beyond its own data."
				>
					<div class="flex flex-col divide-y divide-border">
						{@render toggleRow(
							'Read global memories',
							agent.canReadGlobalMemories,
							(next) => void patch({ canReadGlobalMemories: next })
						)}
						{@render toggleRow(
							'Write global memories',
							agent.canWriteGlobalMemories,
							(next) => void patch({ canWriteGlobalMemories: next })
						)}
						{@render toggleRow(
							'Access global files',
							agent.canAccessGlobalFiles,
							(next) => void patch({ canAccessGlobalFiles: next })
						)}
						{@render toggleRow(
							'Access knowledge',
							agent.canAccessKnowledge,
							(next) => void patch({ canAccessKnowledge: next })
						)}
					</div>
				</Section>
			{:else if section === 'automation'}
				<Section
					title="Scheduling"
					description="Let this agent wake on a heartbeat to work autonomously."
				>
					<div class="flex flex-col divide-y divide-border">
						{@render toggleRow('Paused', agent.isPaused, (next) => void patch({ isPaused: next }))}
						{@render toggleRow(
							'Heartbeat enabled',
							agent.heartbeatEnabled,
							(next) => void patch({ heartbeatEnabled: next })
						)}
					</div>
				</Section>

				<Section
					title="Heartbeat"
					description="How often and with what guidance the agent wakes up."
				>
					<div class="flex flex-col gap-4">
						<Field label="Interval (minutes)" hint="How often the agent wakes to check for work.">
							<input
								type="number"
								min="5"
								bind:value={gHeartbeatInterval}
								class="{CONTROL_CLASS} w-32"
							/>
						</Field>
						<Field label="Instructions" hint="What the agent should do each time it wakes up.">
							<textarea bind:value={gHeartbeatInstructions} rows="5" class={TEXTAREA_CLASS}
							></textarea>
						</Field>
						<Field label="Max daily runs" hint="Caps how many times the agent may wake per day.">
							<input
								type="number"
								min="1"
								bind:value={gMaxDailyRuns}
								class="{CONTROL_CLASS} w-32"
							/>
						</Field>
						{@render saveBar(automationDirty, saveAutomation, resetAutomation)}
						{#if agent.nextScheduledAt}
							<p class="text-xs text-muted-foreground">
								Next wake-up {relativeTime(agent.nextScheduledAt)}
							</p>
						{/if}
					</div>
				</Section>
			{:else if section === 'secrets'}
				<Section
					title="Secrets"
					description="Write-only values injected into the agent's sandbox environment."
				>
					<ul class="divide-y divide-border" data-testid="agent-secrets-list">
						{#each secrets as secret (secret.id)}
							<li class="flex items-center gap-3 py-2 text-sm">
								<code class="font-mono">{secret.key}</code>
								<span class="text-xs text-muted-foreground">{secret.scope}</span>
								<span class="flex-1"></span>
								<span class="font-mono text-xs text-muted-foreground">••••••••</span>
								<button
									type="button"
									class="rounded-md p-1 text-muted-foreground transition-colors hover:text-destructive"
									aria-label="Delete secret {secret.key}"
									onclick={() => void removeSecret(secret.id, secret.key)}
								>
									<Trash2 class="size-3.5" />
								</button>
							</li>
						{:else}
							<li class="py-2 text-sm text-muted-foreground">No secrets configured yet.</li>
						{/each}
					</ul>

					<form
						class="mt-3 flex items-end gap-2 border-t border-border pt-3"
						onsubmit={(event) => {
							event.preventDefault();
							void addSecret();
						}}
					>
						<Field label="Key">
							<input
								bind:value={secretKey}
								placeholder="GITHUB_TOKEN"
								class="{CONTROL_CLASS} font-mono"
							/>
						</Field>
						<Field label="Value">
							<input bind:value={secretValue} type="password" class="{CONTROL_CLASS} font-mono" />
						</Field>
						<Button type="submit" disabled={!secretKey.trim() || !secretValue}>Add</Button>
					</form>
				</Section>
			{:else}
				<Section title="Inbox" description="Events waiting for this agent.">
					<ul class="divide-y divide-border" data-testid="agent-inbox-list">
						{#each inbox as event (event.id)}
							<li class="flex items-start gap-3 py-2 text-sm">
								<span class="min-w-0 flex-1">
									<span class="flex min-w-0 items-center gap-1.5 font-medium">
										<span class="min-w-0 truncate">{event.title ?? event.eventType}</span>
										{#if event.urgency === 'immediate'}
											<span
												class="shrink-0 rounded-full bg-destructive/10 px-1.5 py-0.5 text-[10px] font-medium text-destructive"
											>
												Urgent
											</span>
										{/if}
									</span>
									{#if event.summary}
										<span class="block truncate text-xs text-muted-foreground">
											{event.summary}
										</span>
									{/if}
								</span>
								<span class="shrink-0 text-xs text-muted-foreground">
									{relativeTime(event.insertedAt)}
								</span>
								<span class="shrink-0 text-xs text-muted-foreground capitalize">
									{event.status}
								</span>
								{#if ['pending', 'waiting', 'processing'].includes(event.status)}
									<button
										type="button"
										class="shrink-0 text-xs text-muted-foreground underline-offset-2 hover:text-foreground hover:underline"
										onclick={() => void dismiss(event)}
									>
										Dismiss
									</button>
								{/if}
							</li>
						{:else}
							<li class="py-2 text-sm text-muted-foreground">Inbox is empty.</li>
						{/each}
					</ul>
				</Section>

				<Section title="Activity" description="Recent runs and tool calls by this agent.">
					<ul class="divide-y divide-border" data-testid="agent-activity-list">
						{#each activity as entry (entry.id)}
							<li class="flex items-start gap-3 py-2 text-sm">
								<span class="min-w-0 flex-1">
									{#if entry.conversationId}
										<a
											href="{base}/chat/{entry.conversationId}"
											class="block truncate underline-offset-2 hover:underline"
										>
											{entry.summary}
										</a>
									{:else}
										<span class="block truncate">{entry.summary}</span>
									{/if}
									<span class="block text-xs text-muted-foreground">
										{entry.activityType}
										{#if entry.modelUsed}
											· {entry.modelUsed}{/if}
										{#if entry.tokensUsed}
											· {entry.tokensUsed} tok{/if}
									</span>
								</span>
								<span class="shrink-0 text-xs text-muted-foreground">
									{relativeTime(entry.insertedAt)}
								</span>
							</li>
						{:else}
							<li class="py-2 text-sm text-muted-foreground">No activity yet.</li>
						{/each}
					</ul>
				</Section>
			{/if}
		</fieldset>
	{/if}
</div>
