<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import {
		ArrowRight,
		Bell,
		Bot,
		Brain,
		FileText,
		Globe,
		Paperclip,
		Plus,
		SquareSlash,
		SquareTerminal,
		Users
	} from '@lucide/svelte';
	import {
		chatFeatureLimits,
		deleteFile,
		setConversationImageModel,
		setConversationMode,
		setConversationModel,
		setConversationVideoModel,
		uploadFile,
		type AgentSummary,
		type ChatFeatureLimits,
		type ChatMode,
		type ModelSummary,
		type SlashCommandEntry,
		type UploadedFile
	} from '$lib/ash/api';
	import { cachedActiveModels, cachedMyAgents, cachedSlashCommands } from '$lib/chat/catalog';
	import { imageModalityMismatch } from '$lib/chat/composer-guards';
	import { clearDraft, loadDraft, saveDraft } from '$lib/chat/drafts';
	import {
		detectMention,
		filterAgents,
		insertMention,
		type MentionContext
	} from '$lib/chat/mentions';
	import { setPendingMessage } from '$lib/chat/pending-message';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import ModelPicker from './model-picker.svelte';
	import ModeToggles from './mode-toggles.svelte';
	import PromptPickerDialog from './prompt-picker-dialog.svelte';

	// Minimal shape for the "Chatting with" indicator; both AgentSummary and
	// AgentDetail satisfy it structurally.
	type ChatAgentRef = { id: string; name: string; icon: string | null; imageUrl: string | null };

	// agent: ?agent= deeplink target — seeds the conversation, the indicator and
	// the agent's slash commands. seedText: ?use_prompt= content for user prompts.
	let { agent = null, seedText = null }: { agent?: ChatAgentRef | null; seedText?: string | null } =
		$props();

	// Classic `conversation_id = "new"` parity: the draft lives under a fixed
	// key until the first send creates the real conversation.
	const DRAFT_KEY = 'new';

	let value = $state('');
	let textarea = $state<HTMLTextAreaElement | null>(null);
	let fileInput = $state<HTMLInputElement | null>(null);

	let attachments = $state<UploadedFile[]>([]);
	let uploading = $state(0);
	let uploadError = $state<string | null>(null);

	let agents = $state<AgentSummary[]>([]);
	let models = $state<ModelSummary[]>([]);
	let featureLimits = $state<ChatFeatureLimits | null>(null);
	let slashCommands = $state<SlashCommandEntry[]>([]);
	let mention = $state<MentionContext | null>(null);
	let mentionIndex = $state(0);

	let promptPickerOpen = $state(false);

	// Mode + model are local until the conversation exists, then carried onto it.
	let chatMode = $state<ChatMode>('chat');
	let selectedModelId = $state<string | null>(null);

	let sending = $state(false);
	let sendError = $state<string | null>(null);
	// Once a send hands the uploads off to the new conversation, don't delete
	// them in the unmount cleanup.
	let consumed = false;

	const SLASH_ICONS: Record<string, typeof Globe> = {
		'lucide-globe': Globe,
		'lucide-bell': Bell,
		'lucide-file-text': FileText,
		'lucide-brain': Brain,
		'lucide-users': Users
	};

	function insertPromptContent(content: string) {
		const cursor = textarea?.selectionStart ?? value.length;
		value = value.slice(0, cursor) + content + value.slice(cursor);
		textarea?.focus();
		requestAnimationFrame(autoGrow);
		queueDraftSave();
	}

	/** Classic inject_slash_command: prepend "/name " and focus. */
	function injectSlashCommand(name: string) {
		value = `/${name} ` + value;
		textarea?.focus();
		requestAnimationFrame(autoGrow);
	}

	const suggestions = $derived(mention ? filterAgents(agents, mention.query) : []);
	const mentionOpen = $derived(mention !== null && suggestions.length > 0);

	// Block sending an image to a model that can't read images (parity with the
	// active composer / classic has_modality_mismatch?).
	const selectedModel = $derived(models.find((model) => model.id === selectedModelId) ?? null);
	const modalityMismatch = $derived(imageModalityMismatch(attachments, selectedModel));

	const canSend = $derived(
		value.trim().length > 0 && !sending && uploading === 0 && !modalityMismatch
	);

	let draftTimer: ReturnType<typeof setTimeout> | null = null;

	function queueDraftSave() {
		if (draftTimer) clearTimeout(draftTimer);
		draftTimer = setTimeout(() => saveDraft(localStorage, DRAFT_KEY, value), 400);
	}

	// Plus-menu slash commands: globals when no agent, the agent's own when
	// deeplinked via ?agent=. Reactive so a param change reloads them.
	$effect(() => {
		void cachedSlashCommands(agent?.id ?? null).then((result) => {
			if (result.success) slashCommands = result.data;
		});
	});

	// ?use_prompt= deeplink (user prompts): seed the composer once it resolves,
	// without clobbering an existing draft or anything already typed.
	let seeded = false;
	$effect(() => {
		if (seeded || !seedText) return;
		seeded = true;
		if (value.trim() === '') {
			value = seedText;
			requestAnimationFrame(autoGrow);
			queueDraftSave();
		}
	});

	onMount(() => {
		value = loadDraft(localStorage, DRAFT_KEY);
		void cachedMyAgents().then((result) => {
			if (result.success) agents = result.data;
		});
		void cachedActiveModels().then((result) => {
			if (result.success) models = result.data;
		});
		void chatFeatureLimits().then((result) => {
			if (result.success) featureLimits = result.data;
		});
		requestAnimationFrame(autoGrow);
		return () => {
			if (draftTimer) clearTimeout(draftTimer);
			// Flush the draft so keystrokes inside the debounce window survive a
			// quick navigation away — but not once a send has consumed it, which
			// would re-persist the text and leave it in the box on the next mount.
			if (!consumed) {
				saveDraft(localStorage, DRAFT_KEY, value);
				// Never-sent uploads are discarded so they don't orphan storage quota
				// (skipped once a send has handed them to the new conversation).
				for (const file of attachments) void deleteFile(file.id);
			}
		};
	});

	// Auto-grow up to a cap, then scroll inside the textarea.
	function autoGrow() {
		if (!textarea) return;
		textarea.style.height = 'auto';
		textarea.style.height = `${Math.min(textarea.scrollHeight, 320)}px`;
	}

	function onInput() {
		autoGrow();
		refreshMention();
		queueDraftSave();
	}

	function refreshMention() {
		const caret = textarea?.selectionStart ?? value.length;
		const next = detectMention(value, caret);
		if (next?.start !== mention?.start || next?.query !== mention?.query) mentionIndex = 0;
		mention = next;
	}

	function pickMention(agent: AgentSummary) {
		if (!mention || !textarea) return;
		const caret = textarea.selectionStart ?? value.length;
		const result = insertMention(value, caret, mention, agent.handle);
		value = result.text;
		mention = null;
		requestAnimationFrame(() => {
			textarea?.focus();
			textarea?.setSelectionRange(result.caret, result.caret);
			autoGrow();
		});
	}

	async function attach(files: FileList | File[]) {
		uploadError = null;
		const list = Array.from(files);
		uploading += list.length;

		// No conversation yet — upload into the current workspace scope (classic
		// new-chat parity); the file ids ride along as resources on first send.
		const workspaceId = session.user?.currentWorkspaceId ?? null;
		for (const file of list) {
			const result = await uploadFile(file, workspaceId ? { workspaceId } : {});
			uploading -= 1;
			if (result.success) {
				attachments = [...attachments, result.data];
			} else {
				uploadError = result.errors[0]?.message ?? 'Upload failed';
			}
		}
	}

	function onPaste(event: ClipboardEvent) {
		const files = event.clipboardData?.files;
		if (files && files.length > 0) {
			event.preventDefault();
			void attach(files);
		}
	}

	function removeAttachment(id: string) {
		attachments = attachments.filter((file) => file.id !== id);
		void deleteFile(id);
	}

	/** Image/film toggles flip the local mode to/from the generation modes. */
	function toggleMode(mode: ChatMode) {
		if (mode === 'image_generation' && featureLimits && !featureLimits.imageGenerationEnabled)
			return;
		if (mode === 'video_generation' && featureLimits && !featureLimits.videoGenerationEnabled)
			return;
		chatMode = chatMode === mode ? 'chat' : mode;
	}

	function pickModel(modelId: string | null) {
		selectedModelId = modelId;
	}

	/**
	 * Deferred creation (classic parity): create the conversation only now,
	 * carry over the chosen mode/model, then hand the message to the
	 * conversation route which sends it once its channel is live.
	 */
	async function submit() {
		if (!canSend) return;
		sending = true;
		sendError = null;

		const text = value.trim();
		const resources = attachments.map((file) => ({ type: 'file' as const, id: file.id }));

		const conversation = await workbench.createConversation(
			agent ? { customAgentId: agent.id } : {}
		);
		if (!conversation) {
			sendError = 'Could not start a new chat. Please try again.';
			sending = false;
			return;
		}

		let summary = conversation;
		if (chatMode !== 'chat') {
			const result = await setConversationMode(conversation.id, chatMode);
			if (result.success) summary = result.data;
		}
		if (selectedModelId) {
			// Write the pick into the field for the active mode (parity with the
			// active composer); image/video each have their own model field.
			const result =
				chatMode === 'image_generation'
					? await setConversationImageModel(conversation.id, selectedModelId)
					: chatMode === 'video_generation'
						? await setConversationVideoModel(conversation.id, selectedModelId)
						: await setConversationModel(conversation.id, selectedModelId);
			if (result.success) summary = result.data;
		}
		workbench.upsertConversation(summary);

		setPendingMessage(conversation.id, { text, resources });
		// Cancel any pending debounced save before clearing, otherwise it fires
		// after navigation and re-persists the text — leaving it in the box the
		// next time the landing composer mounts.
		if (draftTimer) clearTimeout(draftTimer);
		value = '';
		clearDraft(localStorage, DRAFT_KEY);
		consumed = true;
		await goto(`${base}/chat/${conversation.id}`);
	}

	function onKeydown(event: KeyboardEvent) {
		if (mentionOpen) {
			if (event.key === 'ArrowDown') {
				event.preventDefault();
				mentionIndex = (mentionIndex + 1) % suggestions.length;
				return;
			}
			if (event.key === 'ArrowUp') {
				event.preventDefault();
				mentionIndex = (mentionIndex - 1 + suggestions.length) % suggestions.length;
				return;
			}
			if (event.key === 'Enter' || event.key === 'Tab') {
				event.preventDefault();
				pickMention(suggestions[mentionIndex]);
				return;
			}
			if (event.key === 'Escape') {
				event.preventDefault();
				mention = null;
				return;
			}
		}

		if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
			event.preventDefault();
			void submit();
		}
	}
</script>

<div class="mx-auto w-full max-w-3xl">
	{#if agent}
		<div
			class="mb-3 flex items-center gap-2 text-xs text-muted-foreground"
			data-testid="landing-composer-agent"
		>
			{#if agent.imageUrl}
				<img src={agent.imageUrl} alt={agent.name} class="size-5 rounded-full object-cover" />
			{:else}
				<span class="flex size-5 items-center justify-center rounded-full bg-secondary text-xs">
					{#if agent.icon}{agent.icon}{:else}<Bot class="size-3" />{/if}
				</span>
			{/if}
			<span>Chatting with <strong class="font-medium text-foreground">{agent.name}</strong></span>
		</div>
	{/if}

	{#if sendError || uploadError}
		<p
			class="pb-1 text-xs text-destructive"
			role="alert"
			id="landing-composer-error"
			data-testid="landing-composer-error"
		>
			{sendError ?? uploadError}
		</p>
	{/if}

	{#if modalityMismatch}
		<p
			class="pb-1 text-xs text-warning"
			role="alert"
			data-testid="landing-composer-modality-warning"
		>
			The selected model can't read images. Pick an image-capable model or remove the image.
		</p>
	{/if}

	{#if attachments.length > 0 || uploading > 0}
		<div class="flex flex-wrap gap-1.5 pb-1.5" data-testid="landing-composer-attachments">
			{#each attachments as file (file.id)}
				<span
					class="inline-flex items-center gap-1.5 rounded-full border border-input bg-secondary px-2.5 py-0.5 text-xs text-secondary-foreground"
				>
					<span class="max-w-40 truncate">{file.name}</span>
					<button
						type="button"
						class="-mr-1 inline-flex size-5 items-center justify-center rounded text-muted-foreground hover:text-foreground"
						aria-label="Remove attachment {file.name}"
						onclick={() => removeAttachment(file.id)}
					>
						×
					</button>
				</span>
			{/each}
			{#if uploading > 0}
				<span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs text-muted-foreground">
					<span
						class="size-3 animate-spin rounded-full border-2 border-current border-t-transparent"
					></span>
					Uploading…
				</span>
			{/if}
		</div>
	{/if}

	<div class="relative">
		{#if mentionOpen}
			<div
				class="absolute bottom-full left-0 z-10 mb-1 w-72 overflow-hidden rounded-lg border bg-popover py-1 text-popover-foreground shadow-md"
				data-testid="mention-dropdown"
			>
				{#each suggestions as agent, index (agent.id)}
					<button
						type="button"
						class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm {index ===
						mentionIndex
							? 'bg-accent text-accent-foreground'
							: 'hover:bg-accent/60'}"
						data-testid="mention-option"
						onmousedown={(event) => {
							event.preventDefault();
							pickMention(agent);
						}}
					>
						<span aria-hidden="true">
							{#if agent.icon}{agent.icon}{:else}<Bot class="size-3.5" />{/if}
						</span>
						<span class="min-w-0">
							<span class="block truncate font-medium">@{agent.handle}</span>
							<span class="block truncate text-xs text-muted-foreground">{agent.name}</span>
						</span>
					</button>
				{/each}
			</div>
		{/if}

		<!-- Mirrors the active-conversation composer's .chat-input-card surface. -->
		<div class="composer-surface rounded-2xl border border-input bg-secondary">
			<textarea
				bind:this={textarea}
				bind:value
				oninput={onInput}
				onkeydown={onKeydown}
				onpaste={onPaste}
				onclick={refreshMention}
				rows="1"
				placeholder="Type your message... (Enter to send, Shift+Enter for new line)"
				aria-describedby={sendError || uploadError ? 'landing-composer-error' : undefined}
				data-testid="landing-composer-input"
				class="max-h-[320px] min-h-[96px] w-full resize-none bg-transparent px-4 pt-3 text-sm outline-none placeholder:text-muted-foreground"
			></textarea>

			<div class="flex items-center gap-1 px-2.5 pb-2">
				<DropdownMenu.Root>
					<DropdownMenu.Trigger
						class="inline-flex size-8 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
						data-testid="landing-composer-actions"
						aria-label="Actions"
					>
						<Plus class="size-[18px]" />
					</DropdownMenu.Trigger>
					<DropdownMenu.Content align="start" class="w-72">
						<DropdownMenu.Item onSelect={() => fileInput?.click()}>
							<Paperclip class="size-4" />
							Attach file
						</DropdownMenu.Item>
						<DropdownMenu.Item
							data-testid="landing-composer-insert-prompt"
							onSelect={() => (promptPickerOpen = true)}
						>
							<SquareTerminal class="size-4" />
							Insert prompt
						</DropdownMenu.Item>
						{#if slashCommands.length > 0}
							<DropdownMenu.Separator />
							{#each slashCommands as command (command.name)}
								{@const Icon = SLASH_ICONS[command.icon ?? ''] ?? SquareSlash}
								<DropdownMenu.Item
									data-testid="landing-composer-slash-command"
									onSelect={() => injectSlashCommand(command.name)}
								>
									<Icon class="size-4" />
									<span class="flex-1">{command.title}</span>
									<span class="ml-2 text-xs font-normal text-muted-foreground">/{command.name}</span
									>
								</DropdownMenu.Item>
							{/each}
						{/if}
					</DropdownMenu.Content>
				</DropdownMenu.Root>

				<ModeToggles
					{chatMode}
					imageEnabled={featureLimits?.imageGenerationEnabled ?? true}
					videoEnabled={featureLimits?.videoGenerationEnabled ?? true}
					onToggle={toggleMode}
				/>

				<ModelPicker {models} {chatMode} {selectedModelId} onPick={pickModel} />

				<input
					bind:this={fileInput}
					type="file"
					multiple
					class="hidden"
					onchange={(event) => {
						const files = event.currentTarget.files;
						if (files && files.length > 0) void attach(files);
						event.currentTarget.value = '';
					}}
				/>

				<div class="flex-1"></div>

				<button
					type="button"
					onclick={() => void submit()}
					disabled={!canSend}
					data-testid="landing-composer-send"
					aria-label="Send message"
					class="inline-flex size-9 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground transition-opacity disabled:opacity-40"
				>
					{#if sending}
						<span
							class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent"
						></span>
					{:else}
						<ArrowRight class="size-4" />
					{/if}
				</button>
			</div>
		</div>
	</div>
</div>

<PromptPickerDialog bind:open={promptPickerOpen} onInsert={insertPromptContent} />
