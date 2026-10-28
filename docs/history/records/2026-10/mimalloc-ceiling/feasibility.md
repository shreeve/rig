# mimalloc in Rig: what it would take

The measuring builds (`build2.sh`) put mimalloc 3.5.3 into Trig with no
change to the compiler: `src/alloc.zig` replaced by a shim
(`alloc-mimalloc.zig`, the bench/hash `:mimalloc` allocator's calls),
and `zig-wrap.sh` as `ZIG`, which adds `-lc` and mimalloc's single-file
build (`src/static.c`, `-O3 -DNDEBUG`, no C sanitizer) to the program's
`zig build-exe`. A real integration would need each of these:

- **libc.** mimalloc as built needs it, and the program then links
  glibc dynamically (`ldd` shows `libc.so.6`). Its Unix layer
  (`src/prim/unix/prim.c`) includes `<sys/mman.h>`, `<unistd.h>`,
  `<errno.h>`, `<stdlib.h>` and `<pthread.h>`, calls `syscall`, reads
  `environ` for its options, and uses `pthread_key_create` and
  `pthread_setspecific` to learn that a thread ended. Without libc it
  links to nothing: Rig's runtime has none of these symbols. Running it
  without libc would mean a primitive layer of our own: mimalloc keeps
  its system calls behind `include/mimalloc/prim.h` (21 functions:
  map, unmap, commit, purge, huge pages, clock, thread id, environment,
  output, random), which Zig could export, plus headers to compile
  against (Zig's bundled musl headers, with no musl linked) and a
  replacement for the thread-exit key (Rig's `threadExit` already marks
  the moment). That is a port, not a flag.
- **libc's own cost.** Linking libc moves Zig's start code, TLS, and
  thread creation to glibc's, which cost 5-7% on Trig in the PGO
  spike's measurement (perf-stage/pgo.md). Variant (d), alloc.zig with
  libc linked, measures that cost apart from the allocator's.
- **Embedding in bin/rig.** As the runtime is: mimalloc's sources
  (`src/*.c`, `src/prim/`, `include/`, about 17,000 lines, MIT
  licensed) embedded and written beside each program, and `rig build`
  adding the C file to the runtime's module. Compiling `static.c` takes
  5.1 s on one of pup's E-cores (`zig cc -O3`), once: Zig's cache keeps
  it for later builds. Trig's executable grows 0.6 MB (126.4 MB against
  125.8).
- **The Mac.** libc (libSystem) is always linked there, so mimalloc
  builds and runs as on Linux, through its `prim/osx` layer; nothing in
  the measurement covers it.
- **`RIG_SANITIZE`.** Unaffected: a sanitized build allocates through
  the runtime's `Sanitizer`, not the release allocator.
- **Leak counting (`__rig_memory`, `os.memory`).** alloc.zig counts each
  heap's bytes and blocks and flushes them in batches; a mimalloc shim
  would count in its vtable (`mi_usable_size` of each block) the same
  way, or read `mi_stats`. The shim measured here leaves `os.memory`
  out, which Trig does not use.
- **Prefault and huge pages.** alloc.zig's `MADV_POPULATE_WRITE` of the
  memory a busy heap is about to fill, and its huge-page advice for
  segments and blocks of 16 MiB or more, have no counterpart: mimalloc
  commits its arenas on demand (`arena_eager_commit` 2, so eagerly
  where overcommit is on), allows large OS pages only when asked
  (`allow_large_os_pages` 0), and purges unused pages after a delay
  (`purge_delay` 1000 ms). Options set at startup (`mi_option_set`)
  could match some of it.
- **PGO.** Rig's `--pgo` pipeline links with no libc and writes its
  profile from Rig's own exit (perf-stage/pgo.md); a program linking
  libc runs glibc's `atexit` instead, and the spike that tried it lost
  8,300 function names to Zig's changed analysis order. So mimalloc
  needs that pipeline reworked, or a no-libc mimalloc; it was not
  measured with PGO here.
