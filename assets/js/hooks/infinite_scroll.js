const InfiniteScroll = {
  mounted() {
    this.observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        if (entry.isIntersecting) {
          this.pushEvent("load_more", {});
        }
      },
      {
        root: null,
        rootMargin: "200px",
        threshold: 0,
      }
    );

    this.observer.observe(this.el);
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },
};

export default InfiniteScroll;
