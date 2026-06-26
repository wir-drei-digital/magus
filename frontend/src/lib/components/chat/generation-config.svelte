<script lang="ts">
	import { ChevronUp, SlidersHorizontal } from '@lucide/svelte';
	import type { ChatMode } from '$lib/ash/api';
	import * as Popover from '$lib/components/ui/popover';
	import {
		IMAGE_ASPECT_RATIOS,
		IMAGE_SIZES,
		VIDEO_ASPECT_RATIOS,
		VIDEO_DURATIONS,
		VIDEO_RESOLUTIONS,
		imageConfigSummary,
		imageGenSettings,
		videoConfigSummary,
		videoGenSettings,
		type ImageGenSettings,
		type VideoGenSettings
	} from '$lib/chat/generation-config';

	let {
		chatMode,
		imageSettingsRaw = null,
		videoSettingsRaw = null,
		onImageChange,
		onVideoChange
	}: {
		chatMode: ChatMode;
		imageSettingsRaw?: unknown;
		videoSettingsRaw?: unknown;
		onImageChange: (settings: ImageGenSettings) => void;
		onVideoChange: (settings: VideoGenSettings) => void;
	} = $props();

	const image = $derived(imageGenSettings(imageSettingsRaw));
	const video = $derived(videoGenSettings(videoSettingsRaw));
	const summary = $derived(
		chatMode === 'image_generation'
			? imageConfigSummary(imageSettingsRaw)
			: videoConfigSummary(videoSettingsRaw)
	);

	function setImage(patch: Partial<ImageGenSettings>) {
		onImageChange({ ...image, ...patch });
	}
	function setVideo(patch: Partial<VideoGenSettings>) {
		onVideoChange({ ...video, ...patch });
	}

	const selectClass =
		'w-full rounded-md border border-input bg-background px-2 py-1 text-xs text-foreground';
	const labelClass = 'font-mono text-[10px] font-medium tracking-wider text-muted-foreground uppercase';
</script>

{#snippet selectField(
	label: string,
	current: string,
	options: { value: string; label: string }[],
	onChange: (value: string) => void
)}
	<div class="flex flex-col gap-1">
		<!-- svelte-ignore a11y_label_has_associated_control — wraps the select -->
		<label class={labelClass}>
			{label}
			<select
				class={selectClass}
				value={current}
				onchange={(event) => onChange(event.currentTarget.value)}
			>
				{#each options as option (option.value)}
					<option value={option.value}>{option.label}</option>
				{/each}
			</select>
		</label>
	</div>
{/snippet}

{#if chatMode === 'image_generation' || chatMode === 'video_generation'}
	<Popover.Root>
		<Popover.Trigger
			class="inline-flex items-center gap-1 rounded-lg px-2 py-1.5 text-xs font-medium text-secondary-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
			data-testid="generation-config"
			title="Generation settings"
		>
			<SlidersHorizontal class="size-3.5" />
			<span class="max-w-44 truncate">{summary}</span>
			<ChevronUp class="size-3" />
		</Popover.Trigger>
		<Popover.Content align="start" side="top" class="w-[min(14rem,calc(100vw-2rem))]">
			{#if chatMode === 'image_generation'}
				{@render selectField(
					'Aspect Ratio',
					image.aspect_ratio,
					IMAGE_ASPECT_RATIOS.map((value) => ({ value, label: value })),
					(value) => setImage({ aspect_ratio: value })
				)}
				{@render selectField(
					'Resolution',
					image.image_size,
					IMAGE_SIZES.map((value) => ({ value, label: value })),
					(value) => setImage({ image_size: value })
				)}
			{:else}
				{@render selectField(
					'Aspect Ratio',
					video.aspect_ratio,
					VIDEO_ASPECT_RATIOS.map((value) => ({ value, label: value })),
					(value) => setVideo({ aspect_ratio: value })
				)}
				{@render selectField(
					'Duration',
					video.duration,
					VIDEO_DURATIONS.map((value) => ({ value, label: `${value}s` })),
					(value) => setVideo({ duration: value })
				)}
				{@render selectField(
					'Resolution',
					video.resolution,
					VIDEO_RESOLUTIONS.map((value) => ({ value, label: value })),
					(value) => setVideo({ resolution: value })
				)}
				<label class="flex cursor-pointer items-center gap-2 py-1">
					<input
						type="checkbox"
						class="size-4 rounded border-input"
						checked={video.generate_audio}
						onchange={(event) => setVideo({ generate_audio: event.currentTarget.checked })}
					/>
					<span class="text-xs text-foreground">Generate audio track</span>
				</label>
			{/if}
		</Popover.Content>
	</Popover.Root>
{/if}
