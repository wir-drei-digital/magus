// Drag-and-drop hooks for the workbench Files mode nav.
//
// `FilesDragSource` makes file rows draggable; `FilesDropTarget` accepts
// drops on folder rows and the section root (Unfiled), calling the
// matching LiveComponent event handler (`move_to_folder` /
// `move_to_root`).
//
// Drop targets are identified by their `data-folder-id` attribute. An
// empty/missing value is interpreted as the section root (move-to-root).
// Hosts may set `data-resource-type` on a target to constrain accepted
// drops; only "file" or "folder" (or unset) accept Files DnD payloads.

export const FilesDropTarget = {
  mounted() {
    this.el.addEventListener("dragover", (e) => {
      // Only accept drops carrying a file id (set by FilesDragSource).
      if (e.dataTransfer.types.includes("text/file-id")) {
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
      }
    });

    this.el.addEventListener("drop", (e) => {
      const targetType = this.el.dataset.resourceType;
      if (targetType && targetType !== "file" && targetType !== "folder") {
        return;
      }

      const fileId = e.dataTransfer.getData("text/file-id");
      if (!fileId) return;
      e.preventDefault();

      // Prefer the new `data-folder-id` attribute (empty/missing => root).
      // Fall back to legacy `data-drop-target-folder` for back-compat.
      const folderId =
        this.el.dataset.folderId ?? this.el.dataset.dropTargetFolder ?? "";
      const isRoot = folderId === "" || folderId === "root";
      const event = isRoot ? "move_to_root" : "move_to_folder";
      const payload = isRoot
        ? { id: fileId }
        : { id: fileId, "folder-id": folderId };

      // The element has phx-target set, so pushEventTo routes the event
      // back to the LiveComponent. Fall back to pushEvent if missing.
      const target = this.el.getAttribute("phx-target");
      if (target) {
        this.pushEventTo(target, event, payload);
      } else {
        this.pushEvent(event, payload);
      }
    });
  },
};

export const FilesDragSource = {
  mounted() {
    this.el.setAttribute("draggable", "true");
    this.el.addEventListener("dragstart", (e) => {
      e.dataTransfer.setData("text/file-id", this.el.dataset.fileId);
      e.dataTransfer.effectAllowed = "move";
    });
  },
};
