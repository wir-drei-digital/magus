/**
 * Shared CRUD kit — the documented vocabulary for resource forms across the SPA
 * (agents, prompts, settings, workspaces). Prefer these over hand-rolled markup
 * so every create/detail/edit surface stays consistent.
 *
 * - `Section`  — titled card container (with `variant="danger"` + header actions)
 * - `Field`    — labelled control wrapper (label + hint + error)
 * - `ToggleSwitch` — accessible boolean switch (not a raw checkbox)
 * - `Button`   — the primary/secondary/destructive action primitive
 * - `confirmAction` — promise-based branded confirm for destructive actions
 * - `CONTROL_CLASS` / `TEXTAREA_CLASS` — canonical input/select/textarea styling
 */
export { default as Section } from './section.svelte';
export { default as Field } from './field.svelte';
export { default as ToggleSwitch } from './toggle-switch.svelte';
export { Button } from '$lib/components/ui/button';
export { confirmAction } from '$lib/stores/confirm.svelte';
export { CONTROL_CLASS, TEXTAREA_CLASS } from './styles';
