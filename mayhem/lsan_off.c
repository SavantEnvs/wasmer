/* Fleet policy: disable LeakSanitizer at build time (ASan stays on). Linked into every fuzz binary. */
int __lsan_is_turned_off(void) { return 1; }
