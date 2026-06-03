/**
 * JoinPartyForm — Extracts invite code from input (link or raw code)
 * and navigates to the join page.
 */
const JoinPartyForm = {
  mounted() {
    // Bind so `destroyed()` can detach the same reference (this.el
    // listener cleans up with the element, but explicit removal keeps
    // the pattern consistent with the other hooks).
    this.onSubmit = (e) => {
      e.preventDefault();
      const input = this.el.querySelector("input[name=invite]");
      const value = (input?.value || "").trim();
      if (!value) return;

      const code = this._extractCode(value);
      if (code) {
        window.location.href = `/party/${code}`;
      }
    };

    this.el.addEventListener("submit", this.onSubmit);
  },

  destroyed() {
    this.el?.removeEventListener("submit", this.onSubmit);
  },

  _extractCode(value) {
    // Full URL: /party/abc123 or /party/abc123/watch
    const urlMatch = value.match(/\/party\/([a-z0-9]+)/i);
    if (urlMatch) return urlMatch[1].toLowerCase();

    // Raw code (6 alphanumeric chars)
    const raw = value.replace(/\s/g, "").toLowerCase();
    if (/^[a-z0-9]{4,8}$/.test(raw)) return raw;

    return null;
  },
};

export default JoinPartyForm;
