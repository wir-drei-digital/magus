export type BucketOption = { value: string | null; label: string };

export function bucketOptions(
	workspaces: Array<{ id: string; name: string }>,
	_currentWorkspaceId: string | null
): BucketOption[] {
	return [
		{ value: null, label: 'Personal' },
		...workspaces.map((w) => ({ value: w.id, label: w.name }))
	];
}
