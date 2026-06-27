import { describe, expect, it } from "vitest";
import { partitionSkills } from "./skills-nav.svelte";

describe("partitionSkills", () => {
	it("splits personal (no workspace) from workspace", () => {
		const skills = [
			{ id: "1", name: "a", workspaceId: null, isSharedToWorkspace: false },
			{ id: "2", name: "b", workspaceId: "ws", isSharedToWorkspace: true }
		] as any;
		const { personal, workspace } = partitionSkills(skills, "ws");
		expect(personal.map((s: any) => s.id)).toEqual(["1"]);
		expect(workspace.map((s: any) => s.id)).toEqual(["2"]);
	});

	it("returns empty buckets for an empty list", () => {
		const { personal, workspace } = partitionSkills([], "ws");
		expect(personal).toEqual([]);
		expect(workspace).toEqual([]);
	});

	it("places all skills in personal when none have a workspaceId", () => {
		const skills = [
			{ id: "1", name: "a", workspaceId: null, isSharedToWorkspace: false },
			{ id: "2", name: "b", workspaceId: null, isSharedToWorkspace: false }
		] as any;
		const { personal, workspace } = partitionSkills(skills, "ws");
		expect(personal.map((s: any) => s.id)).toEqual(["1", "2"]);
		expect(workspace).toEqual([]);
	});
});
