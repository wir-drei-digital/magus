/**
 * DraggableMessage LiveView hook.
 *
 * Attached to a small drag handle inside a chat message. The handle is
 * draggable so the whole message can be dropped onto the brain editor
 * pane to create a message block. The surrounding message bubble itself
 * is not draggable, so text selection inside messages still works.
 */
const DraggableMessage = {
  mounted() {
    this.el.addEventListener("dragstart", (e) => {
      e.dataTransfer.setData(
        "application/x-brain-message",
        JSON.stringify({
          messageId: this.el.dataset.messageId,
          conversationId: this.el.dataset.conversationId,
          text: this.el.dataset.text,
        }),
      );
      e.dataTransfer.effectAllowed = "copy";

      const bubble = this.el.closest(".message-bubble");
      if (bubble) {
        const rect = bubble.getBoundingClientRect();
        e.dataTransfer.setDragImage(
          bubble,
          e.clientX - rect.left,
          e.clientY - rect.top,
        );
        bubble.classList.add("opacity-50");
        this._draggingBubble = bubble;
      }
    });

    this.el.addEventListener("dragend", () => {
      if (this._draggingBubble) {
        this._draggingBubble.classList.remove("opacity-50");
        this._draggingBubble = null;
      }
    });
  },
};

export default DraggableMessage;
