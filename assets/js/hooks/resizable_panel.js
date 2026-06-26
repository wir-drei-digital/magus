/**
 * ResizablePanel LiveView hook.
 *
 * Enables vertical resizing of a panel by dragging a handle element.
 * The handle is identified by the `.brain-resize-handle` class within
 * the hook element. Dragging up increases height, dragging down decreases.
 */
const ResizablePanel = {
  mounted() {
    this.handle = this.el.querySelector(".brain-resize-handle");
    if (!this.handle) return;

    this._onMouseDown = (e) => {
      e.preventDefault();
      this._startY = e.clientY;
      this._startHeight = this.el.offsetHeight;

      document.addEventListener("mousemove", this._onMouseMove);
      document.addEventListener("mouseup", this._onMouseUp);
      document.body.style.cursor = "row-resize";
      document.body.style.userSelect = "none";
    };

    this._onMouseMove = (e) => {
      // Dragging up (negative delta) should increase height
      const delta = this._startY - e.clientY;
      const newHeight = Math.max(80, Math.min(this._startHeight + delta, window.innerHeight * 0.5));
      this.el.style.height = `${newHeight}px`;
    };

    this._onMouseUp = () => {
      document.removeEventListener("mousemove", this._onMouseMove);
      document.removeEventListener("mouseup", this._onMouseUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };

    this.handle.addEventListener("mousedown", this._onMouseDown);
  },

  destroyed() {
    if (this.handle) {
      this.handle.removeEventListener("mousedown", this._onMouseDown);
    }
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
  },
};

export default ResizablePanel;
