<script lang="ts">
	import { Image as ImageIcon, Trash2, Upload, Wand2 } from '@lucide/svelte';
	import {
		generateProfileImage,
		removeProfileImage,
		uploadProfileImage,
		type ProfileImageTarget
	} from '$lib/ash/api';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';

	let {
		target,
		currentUrl = null,
		onUpdated,
		rounded = true
	}: {
		target: ProfileImageTarget;
		currentUrl?: string | null;
		/** Called with the new image URL (or null after removal). */
		onUpdated: (url: string | null) => void;
		rounded?: boolean;
	} = $props();

	const INPUT =
		'w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60';

	// Labels mirror MagusWeb.ProfileImageGeneratorComponent / the controller suffixes.
	const STYLES = [
		{ value: 'none', label: 'None' },
		{ value: 'photo', label: 'Photo realistic' },
		{ value: 'flat', label: 'Flat' },
		{ value: 'pixel', label: 'Pixel art' },
		{ value: 'threeD', label: '3D' },
		{ value: 'cartoon', label: 'Cartoon' },
		{ value: 'emoji', label: 'Emoji' },
		{ value: 'minimal', label: 'Minimal' },
		{ value: 'watercolor', label: 'Watercolor' }
	];

	let fileInput = $state<HTMLInputElement | null>(null);
	let busy = $state(false);
	let error = $state<string | null>(null);

	let genOpen = $state(false);
	let prompt = $state('');
	let style = $state('none');
	let generating = $state(false);
	let genError = $state<string | null>(null);

	async function onFile(file: File) {
		busy = true;
		error = null;
		const result = await uploadProfileImage(file, target);
		busy = false;
		if (result.success) onUpdated(result.data.url);
		else error = result.errors[0]?.message ?? 'Upload failed';
	}

	async function remove() {
		busy = true;
		error = null;
		const result = await removeProfileImage(target);
		busy = false;
		if (result.success) onUpdated(null);
		else error = result.errors[0]?.message ?? 'Could not remove image';
	}

	async function generate() {
		if (prompt.trim() === '' || generating) return;
		generating = true;
		genError = null;
		const result = await generateProfileImage(prompt.trim(), style, target);
		generating = false;
		if (result.success) {
			onUpdated(result.data.url);
			genOpen = false;
			prompt = '';
		} else {
			genError = result.errors[0]?.message ?? 'Generation failed';
		}
	}
</script>

<div class="flex items-center gap-4" data-testid="profile-image-picker">
	<span
		class="flex size-16 shrink-0 items-center justify-center overflow-hidden border bg-secondary {rounded
			? 'rounded-full'
			: 'rounded-lg'}"
	>
		{#if currentUrl}
			<img src={currentUrl} alt="" class="size-full object-cover" />
		{:else}
			<ImageIcon class="size-6 text-muted-foreground" />
		{/if}
	</span>

	<div class="flex flex-col gap-2">
		<div class="flex flex-wrap gap-2">
			<Button
				type="button"
				variant="outline"
				size="sm"
				disabled={busy}
				onclick={() => fileInput?.click()}
				data-testid="profile-image-upload"
			>
				<Upload class="size-4" />
				Upload
			</Button>
			<Button
				type="button"
				variant="outline"
				size="sm"
				disabled={busy}
				onclick={() => (genOpen = true)}
				data-testid="profile-image-generate"
			>
				<Wand2 class="size-4" />
				Generate
			</Button>
			{#if currentUrl}
				<Button
					type="button"
					variant="ghost"
					size="sm"
					disabled={busy}
					onclick={() => void remove()}
					data-testid="profile-image-remove"
				>
					<Trash2 class="size-4" />
					Remove
				</Button>
			{/if}
		</div>
		{#if busy}
			<p class="text-xs text-muted-foreground">Working…</p>
		{:else if error}
			<p class="text-xs text-destructive">{error}</p>
		{/if}
	</div>

	<input
		bind:this={fileInput}
		type="file"
		accept="image/png,image/jpeg,image/gif,image/webp"
		class="hidden"
		onchange={(event) => {
			const file = event.currentTarget.files?.[0];
			if (file) void onFile(file);
			event.currentTarget.value = '';
		}}
	/>
</div>

<Dialog.Root bind:open={genOpen}>
	<Dialog.Content class="sm:max-w-md" data-testid="generate-image-dialog">
		<Dialog.Header>
			<Dialog.Title>Generate image</Dialog.Title>
			<Dialog.Description
				>Describe the image. Generation can take up to a minute.</Dialog.Description
			>
		</Dialog.Header>
		<form
			class="flex flex-col gap-3"
			onsubmit={(event) => {
				event.preventDefault();
				void generate();
			}}
		>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Prompt</span>
				<input
					type="text"
					bind:value={prompt}
					placeholder="A friendly robot mascot"
					class={INPUT}
					data-testid="generate-image-prompt"
				/>
			</label>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Style</span>
				<select bind:value={style} class={INPUT} data-testid="generate-image-style">
					{#each STYLES as option (option.value)}
						<option value={option.value}>{option.label}</option>
					{/each}
				</select>
			</label>
			{#if genError}
				<p class="text-xs text-destructive">{genError}</p>
			{/if}
			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (genOpen = false)}>Cancel</Button>
				<Button
					type="submit"
					disabled={prompt.trim() === '' || generating}
					data-testid="generate-image-submit"
				>
					{generating ? 'Generating…' : 'Generate'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
