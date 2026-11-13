#!/usr/bin/env bash
# Source this from local build/test entry points. Keep the laptop usable while
# compiling FluidAudio/WhisperKit, including whole-module Release compilation.
WIMM_BUILD_JOBS="${WIMM_BUILD_JOBS:-2}"
if [[ ! "$WIMM_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "WIMM_BUILD_JOBS must be a positive integer" >&2
  return 2
fi

wimm_swift() {
  local command="$1"
  shift
  # Let llbuild own build.db. Rewriting its dependency lists invalidates the
  # cache; object files and test sources can both be legitimate dependencies.
  # SwiftPM emits package-trait -D flags by iterating a Set. Random hash seeds
  # can reorder identical traits on replanning and invalidate FluidAudio.
  # Scope deterministic hashing to this build invocation, never the shell or
  # the installed app launched afterwards.
  SWIFT_DETERMINISTIC_HASHING=1 nice -n 10 swift "$command" --jobs "$WIMM_BUILD_JOBS" \
    -Xswiftc -num-threads -Xswiftc "$WIMM_BUILD_JOBS" "$@"
}

wimm_xcodebuild() {
  # Archive recreates its build state; the compiler cache survives it.
  # Real iOS archives: 234 s cold, 17 s warm (see docs/Local_Build_Budget.md).
  nice -n 10 xcodebuild -jobs "$WIMM_BUILD_JOBS" \
    COMPILATION_CACHE_ENABLE_CACHING=YES \
    "OTHER_SWIFT_FLAGS=\$(inherited) -num-threads $WIMM_BUILD_JOBS" "$@"
}
