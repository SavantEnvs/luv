#!/usr/bin/env bash
#
# mayhem/build.sh — builds luv twice, out of tree under build/ (gitignored upstream):
#   build/oracle  the project's normal build (PUC Lua 5.4 + luv.so module), what test.sh runs
#   build/fuzz    sanitized static luv + libuv + Lua, linked into the fuzz harness
# Everything comes from the checkout (deps/ submodules), so a re-run needs no network.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

for d in deps/libuv/include deps/lua/lua.h deps/lua-compat-5.3/c-api; do
  [ -e "$d" ] || { echo "missing $d: submodules not checked out" >&2; exit 1; }
done

# SanCov on the library objects is what gives Mayhem edges inside luv/libuv/Lua; it is added
# unconditionally so the no-sanitizer build still has coverage.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"

# 1) Test build, project's normal flags (upstream's Makefile defaults, PUC Lua 5.4).
cmake -S . -B build/oracle -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DBUILD_MODULE=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_SHARED_LIBS=OFF \
  -DWITH_LUA_ENGINE=Lua -DLUA_BUILD_TYPE=Static \
  -DLUA_COMPAT53_DIR=deps/lua-compat-5.3 \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"
cmake --build build/oracle -j"$MAYHEM_JOBS"
# upstream's `make test` also runs the EXCLUDE_FROM_ALL embedding host (src/test.c) on
# tests/manual-test-external-loop.lua; build it here so test.sh only runs it.
cmake --build build/oracle -j"$MAYHEM_JOBS" --target test
ln -sf build/oracle/luv.so luv.so

# 2) Sanitized static libraries for the harness. RelWithDebInfo's default flags carry -DNDEBUG,
#    which would compile libuv's/luv's assert()s out of the fuzzed code: override them to plain
#    -O2 (DEBUG_FLAGS already supplies -g -gdwarf-3) so the asserts stay in.
cmake -S . -B build/fuzz -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2" \
  -DBUILD_MODULE=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF \
  -DWITH_LUA_ENGINE=Lua -DLUA_BUILD_TYPE=Static \
  -DLUA_COMPAT53_DIR=deps/lua-compat-5.3 \
  -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS"
cmake --build build/fuzz -j"$MAYHEM_JOBS" --target libluv_a uv_a lualib

LIBS=("$SRC/build/fuzz/libluv.a" "$SRC/build/fuzz/deps/libuv/libuv.a" "$SRC/build/fuzz/liblua55.a")
for l in "${LIBS[@]}"; do [ -f "$l" ] || { echo "missing $l" >&2; exit 1; }; done
SYSLIBS=(-lm -ldl -lpthread -lrt)
INCS=(-I"$SRC/src" -I"$SRC/deps/lua" -I"$SRC/deps/libuv/include" -I"$SRC/deps/lua-compat-5.3/c-api")

# 3) Harness: fuzzer binary + standalone reproducer, leak detection off at build time.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -c "$SRC/mayhem/fuzz_luv.c" "${INCS[@]}" -o /tmp/fuzz_luv.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE /tmp/fuzz_luv.o /tmp/lsan_off.o \
  "${LIBS[@]}" "${SYSLIBS[@]}" -o /mayhem/fuzz_luv
$CC $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/standalone_main.o /tmp/fuzz_luv.o /tmp/lsan_off.o \
  "${LIBS[@]}" "${SYSLIBS[@]}" -o /mayhem/fuzz_luv-standalone
