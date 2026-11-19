/*
 * fuzz_luv: runs fuzzer-provided bytes as a Lua script against luv (libuv bindings for Lua).
 *
 * The script sees only a curated `uv` table: handle objects (timer/idle/prepare/check/async),
 * the event loop (run is pinned to "nowait"), read-only fs calls (open is pinned to read-only,
 * non-blocking, and keeps only regular files and directories; fs_read lengths are capped at
 * READ_MAX, since luv mallocs the requested length outside the Lua allocator cap), the
 * directory/scandir requests, semaphores and the pure conversion/query helpers. Anything that
 * spawns processes, signals, writes or deletes files, touches the network, changes process
 * state, starts threads or blocks (including the uv_sem `wait` method) is not exposed, so an input only ever depends on itself.
 *
 * File descriptors are the one thing luv hands out that the Lua state does not own, so the
 * harness owns them: it records every fd that fs_open returns (also through the async
 * callback), lets fs_close/fs_read/fs_fstat act only on recorded fds (anything else gets
 * EBADF, so a script cannot touch fd 0/1/2 or libFuzzer's own descriptors) and closes
 * whatever is still open when an input ends. Open fds are capped at MAX_FDS per input.
 *
 * Requests that run on libuv's thread pool are awaited before control returns to the script
 * (and before lua_close), so a run does not depend on worker-thread scheduling.
 *
 * Bounds on the Lua side only (deterministic, no clocks): a 64 MiB allocator cap and an
 * instruction budget, so a script cannot turn the run into a Lua-level infinite loop or an
 * allocator OOM. Callback errors are swallowed through luv's documented luv_set_callback hook
 * (the default routine calls exit(-1) on any uncaught Lua error in a callback).
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "luv.h"

#define MEM_LIMIT ((size_t)64 << 20)
#define INSN_BUDGET 2000000L
#define HOOK_STEP 1000
#define DRAIN_ROUNDS 8
#define MAX_FDS 32
#define READ_MAX ((lua_Integer)4 << 20)

static size_t mem_used;
static long insn_left;
static int cb_depth;
static int open_fds[MAX_FDS];
static int n_open_fds;
static int n_pending_opens;

static void *capped_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud;
  size_t old = ptr ? osize : 0;
  if (nsize == 0) {
    mem_used -= old;
    free(ptr);
    return NULL;
  }
  if (mem_used - old + nsize > MEM_LIMIT) return NULL;
  void *p = realloc(ptr, nsize);
  if (p) mem_used += nsize - old;
  return p;
}

static void budget_hook(lua_State *L, lua_Debug *ar) {
  (void)ar;
  insn_left -= HOOK_STEP;
  if (insn_left < 0) luaL_error(L, "instruction budget exhausted");
}

static int swallow_errors(lua_State *L, int nargs, int nresults, int flags) {
  cb_depth++;
  int rc = luv_cfpcall(L, nargs, nresults, flags | LUVF_CALLBACK_NOEXIT | LUVF_CALLBACK_NOERRMSG);
  cb_depth--;
  return rc;
}

/* Wait for every request handed to the thread pool to finish, so what a script sees never
 * depends on how the worker threads were scheduled against the main thread. */
static void settle(uv_loop_t *loop) {
  if (cb_depth > 0) return;
  for (int i = 0; i < 100000 && loop->active_reqs.count > 0; i++) uv_run(loop, UV_RUN_ONCE);
}

static int uv_run_nowait(lua_State *L) {
  if (cb_depth > 0) return 0; /* uv_run is not reentrant */
  lua_settop(L, 0);
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_pushstring(L, "nowait");
  lua_call(L, 1, LUA_MULTRET);
  settle(luv_loop(L));
  return lua_gettop(L);
}

static int uv_settled(lua_State *L) {
  int top = lua_gettop(L);
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_insert(L, 1);
  lua_call(L, top, LUA_MULTRET);
  settle(luv_loop(L));
  return lua_gettop(L);
}

static int fd_index(lua_Integer fd) {
  for (int i = 0; i < n_open_fds; i++)
    if (open_fds[i] == fd) return i;
  return -1;
}

static void fd_track(int fd) {
  if (n_open_fds < MAX_FDS)
    open_fds[n_open_fds++] = fd;
  else
    close(fd); /* unreachable: opens are admitted against MAX_FDS */
}

static void fd_untrack(int i) { open_fds[i] = open_fds[--n_open_fds]; }

static void close_open_fds(void) {
  while (n_open_fds > 0) close(open_fds[--n_open_fds]);
  n_pending_opens = 0;
}

static int push_fs_error(lua_State *L, const char *name, const char *msg) {
  lua_pushnil(L);
  lua_pushfstring(L, "%s: %s", name, msg);
  lua_pushstring(L, name);
  return 3;
}

/* Only regular files and directories: a device, FIFO or socket (/dev/stdin, /dev/tty,
 * /proc/self/fd/N) could block a sync fs_read until the exec timeout. */
static int fd_acceptable(int fd) {
  struct stat st;
  if (fstat(fd, &st) == 0 && (S_ISREG(st.st_mode) || S_ISDIR(st.st_mode))) return 1;
  close(fd);
  return 0;
}

/* fs_open callback: record the fd, then run the script's callback with the same arguments. */
static int fs_open_cb(lua_State *L) {
  int nargs = lua_gettop(L);
  if (n_pending_opens > 0) n_pending_opens--;
  if (lua_isinteger(L, 2)) {
    if (fd_acceptable((int)lua_tointeger(L, 2))) {
      fd_track((int)lua_tointeger(L, 2));
    } else {
      lua_pushstring(L, "EINVAL: not a regular file or directory");
      lua_replace(L, 1);
      lua_pushnil(L);
      lua_replace(L, 2);
    }
  }
  lua_pushvalue(L, lua_upvalueindex(1));
  for (int i = 1; i <= nargs; i++) lua_pushvalue(L, i);
  lua_call(L, nargs, 0);
  return 0;
}

static int is_callable(lua_State *L, int idx) {
  if (lua_isfunction(L, idx)) return 1;
  if (luaL_getmetafield(L, idx, "__call") == LUA_TNIL) return 0;
  lua_pop(L, 1);
  return 1;
}

static int uv_fs_open_readonly(lua_State *L) {
  int top = lua_gettop(L);
  int async = top >= 4 && !lua_isnil(L, 4) && is_callable(L, 4);
  if (n_open_fds + n_pending_opens >= MAX_FDS) return push_fs_error(L, "EMFILE", "too many open files");
  lua_pushvalue(L, lua_upvalueindex(1));
  for (int i = 1; i <= top; i++) {
    if (i == 2)
      lua_pushinteger(L, O_RDONLY | O_NONBLOCK | O_NOCTTY);
    else if (i == 4 && async) {
      lua_pushvalue(L, i);
      lua_pushcclosure(L, fs_open_cb, 1);
    } else
      lua_pushvalue(L, i);
  }
  lua_call(L, top, LUA_MULTRET);
  int nres = lua_gettop(L) - top;
  if (nres > 0) {
    if (async) {
      if (!lua_isnil(L, top + 1)) n_pending_opens++; /* a request is on the thread pool */
    } else if (lua_isinteger(L, top + 1)) {
      if (!fd_acceptable((int)lua_tointeger(L, top + 1))) {
        lua_settop(L, top);
        return push_fs_error(L, "EINVAL", "not a regular file or directory");
      }
      fd_track((int)lua_tointeger(L, top + 1));
    }
  }
  return nres;
}

/* fs_close / fs_read / fs_fstat: only for fds fs_open returned and the script has not closed. */
static int uv_fs_fd_checked(lua_State *L) {
  int top = lua_gettop(L);
  int isnum;
  lua_Integer fd = lua_tointegerx(L, 1, &isnum);
  int idx = isnum ? fd_index(fd) : -1;
  if (isnum && idx < 0) return push_fs_error(L, "EBADF", "bad file descriptor");
  if (lua_toboolean(L, lua_upvalueindex(3)) && top >= 2) {
    /* fs_read: luv mallocs the requested length; keep it bounded like the Lua heap */
    lua_Integer len = lua_tointegerx(L, 2, &isnum);
    if (isnum && len > READ_MAX) {
      lua_pushinteger(L, READ_MAX);
      lua_replace(L, 2);
    }
  }
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_insert(L, 1);
  lua_call(L, top, LUA_MULTRET);
  int nres = lua_gettop(L);
  if (idx >= 0 && lua_toboolean(L, lua_upvalueindex(2)) && nres > 0 && !lua_isnil(L, 1)) {
    /* fs_close went through (or is queued): the fd is no longer ours to close */
    int j = fd_index(fd);
    if (j >= 0) fd_untrack(j);
  }
  return nres;
}

static const char *const exposed[] = {
    "loop_alive", "stop", "now", "update_time", "walk", "cancel", "req_get_type",
    "is_active", "is_closing", "close", "ref", "unref", "has_ref", "handle_get_type",
    "new_timer", "timer_start", "timer_stop", "timer_again", "timer_set_repeat",
    "timer_get_repeat", "timer_get_due_in",
    "new_prepare", "prepare_start", "prepare_stop",
    "new_check", "check_start", "check_stop",
    "new_idle", "idle_start", "idle_stop",
    "new_async", "async_send",
    "fs_scandir_next",
    "new_sem", "sem_post", "sem_trywait",
    "available_parallelism", "get_total_memory", "get_free_memory", "get_constrained_memory",
    "get_available_memory", "hrtime", "loadavg", "version", "version_string", "uptime",
    "translate_sys_error", "utf16_length_as_wtf8", "utf16_to_wtf8", "wtf8_length_as_utf16",
    "wtf8_to_utf16", "metrics_idle_time", "metrics_info", "guess_handle",
    "gettimeofday", "clock_gettime", "cpumask_size", "os_uname", "getrusage", "cpu_info",
    "interface_addresses", "os_getpid", "os_getppid", "os_gethostname", "os_tmpdir",
    "os_homedir", "getuid", "getgid", "cwd", "exepath", "resident_set_memory",
    "if_indextoname", "if_indextoiid", "constants", "errno",
};

/* Functions that take an optional callback and then run on the thread pool. */
static const char *const threadpool_fns[] = {
    "fs_scandir", "fs_stat", "fs_lstat", "fs_access",
    "fs_readlink", "fs_realpath", "fs_opendir", "fs_readdir", "fs_closedir", "fs_statfs",
    "random",
};

/* The threadpool functions that take a file descriptor. */
static const char *const fd_fns[] = {"fs_close", "fs_read", "fs_fstat"};

static const char *const removed_globals[] = {
    "dofile", "loadfile", "load", "print", "getmetatable",
};

static void install_uv(lua_State *L) {
  luaL_requiref(L, "luv", luaopen_luv, 0); /* full luv table */
  /* Semaphores are exposed for post/trywait, but every uv_sem userdata reaches the blocking
   * `wait` through its metatable's __index (method syntax needs no getmetatable). Nothing else
   * can post while the single fuzzer thread waits, so drop it from the method table. */
  luaL_getmetatable(L, "uv_sem");
  lua_getfield(L, -1, "__index");
  lua_pushnil(L);
  lua_setfield(L, -2, "wait");
  lua_pop(L, 2);
  lua_newtable(L);                         /* the curated one */
  for (size_t i = 0; i < sizeof(exposed) / sizeof(exposed[0]); i++) {
    lua_getfield(L, -2, exposed[i]);
    if (lua_isnil(L, -1))
      lua_pop(L, 1);
    else
      lua_setfield(L, -2, exposed[i]);
  }
  for (size_t i = 0; i < sizeof(threadpool_fns) / sizeof(threadpool_fns[0]); i++) {
    lua_getfield(L, -2, threadpool_fns[i]);
    lua_pushcclosure(L, uv_settled, 1);
    lua_setfield(L, -2, threadpool_fns[i]);
  }
  for (size_t i = 0; i < sizeof(fd_fns) / sizeof(fd_fns[0]); i++) {
    lua_getfield(L, -2, fd_fns[i]);
    lua_pushboolean(L, strcmp(fd_fns[i], "fs_close") == 0);
    lua_pushboolean(L, strcmp(fd_fns[i], "fs_read") == 0);
    lua_pushcclosure(L, uv_fs_fd_checked, 3);
    lua_pushcclosure(L, uv_settled, 1);
    lua_setfield(L, -2, fd_fns[i]);
  }
  lua_getfield(L, -2, "run");
  lua_pushcclosure(L, uv_run_nowait, 1);
  lua_setfield(L, -2, "run");
  lua_getfield(L, -2, "fs_open");
  lua_pushcclosure(L, uv_fs_open_readonly, 1);
  lua_pushcclosure(L, uv_settled, 1);
  lua_setfield(L, -2, "fs_open");
  lua_setglobal(L, "uv");
  lua_pop(L, 1); /* full luv table */
}

static void sandbox_globals(lua_State *L) {
  for (size_t i = 0; i < sizeof(removed_globals) / sizeof(removed_globals[0]); i++) {
    lua_pushnil(L);
    lua_setglobal(L, removed_globals[i]);
  }
  lua_getglobal(L, "string");
  lua_pushnil(L);
  lua_setfield(L, -2, "dump");
  lua_pop(L, 1);
}

static lua_State *new_state(void) {
  lua_State *L = lua_newstate(capped_alloc, NULL, 0);
  if (!L) return NULL;
  luv_set_callback(L, swallow_errors);
  luaL_requiref(L, "_G", luaopen_base, 1);
  luaL_requiref(L, "string", luaopen_string, 1);
  luaL_requiref(L, "table", luaopen_table, 1);
  luaL_requiref(L, "math", luaopen_math, 1);
  luaL_requiref(L, "utf8", luaopen_utf8, 1);
  luaL_requiref(L, "coroutine", luaopen_coroutine, 1);
  lua_settop(L, 0);
  install_uv(L);
  sandbox_globals(L);
  lua_settop(L, 0);
  return L;
}

static void drain_loop(lua_State *L) {
  uv_loop_t *loop = luv_loop(L);
  settle(loop);
  for (int i = 0; i < DRAIN_ROUNDS; i++) {
    if (!uv_loop_alive(loop)) break;
    uv_run(loop, UV_RUN_NOWAIT);
    settle(loop);
  }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size == 0 || size > 8192) return -1;
  mem_used = 0;
  cb_depth = 0;
  n_open_fds = 0;
  n_pending_opens = 0;
  insn_left = INSN_BUDGET;
  lua_State *L = new_state();
  if (!L) return -1;
  int rc = luaL_loadbufferx(L, (const char *)data, size, "=fuzz", "t");
  if (rc != LUA_OK) {
    lua_close(L);
    return -1;
  }
  lua_sethook(L, budget_hook, LUA_MASKCOUNT, HOOK_STEP);
  lua_pcall(L, 0, 0, 0);
  drain_loop(L);
  close_open_fds();
  lua_close(L);
  return 0;
}
