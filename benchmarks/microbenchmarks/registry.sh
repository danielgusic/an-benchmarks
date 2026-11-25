# Shared by run.sh and inject.sh; sourced, not executed. Expects HERE and ROOT.
#
# Environment:
#   BENCH_CONF    registry file (default: benches.conf)
#   BENCHES       only these registry names
#   MODES         off and/or an (default: "off an")
#   AN_CONSTANT   override the AN constant A
#
# Defines HOST, CONF, RESULTS, MODES, the registry arrays NAMES, WASMS,
# PARAMS, ITERS, WARMUPS, SAMPLES, CHECKSUMS (empty = unknown), plus
# set_an_args MODE and write_meta FILE [EXTRA].

HOST="$HERE/host/target/release/micro-host"
CONF="${BENCH_CONF:-$HERE/benches.conf}"
RESULTS="$HERE/results"
read -r -a MODES <<< "${MODES:-off an}"
read -r -a FILTER <<< "${BENCHES:-}"

[[ -x "$HOST" ]] || { echo "missing $HOST -- run ./setup.sh first" >&2; exit 1; }
[[ -f "$CONF" ]] || { echo "missing registry $CONF" >&2; exit 1; }
for mode in "${MODES[@]}"; do
  [[ "$mode" == off || "$mode" == an ]] || { echo "MODES may only contain off and an, got $mode" >&2; exit 2; }
done
[[ ${#MODES[@]} -gt 0 ]] || { echo "MODES is empty" >&2; exit 2; }
[[ -z "${AN_CONSTANT:-}" || "$AN_CONSTANT" =~ ^[0-9]+$ ]] || { echo "AN_CONSTANT must be a number" >&2; exit 2; }

NAMES=(); WASMS=(); PARAMS=(); ITERS=(); WARMUPS=(); SAMPLES=(); CHECKSUMS=()
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  line="${line%%#*}"
  read -r name wasm param iters warmup samples expect rest <<< "$line" || true
  [[ -z "${name:-}" ]] && continue
  if [[ -n "${rest:-}" || -z "${expect:-}" || ! "$name" =~ ^[A-Za-z0-9_-]+$ ]] \
     || ! [[ "$param" =~ ^[0-9]+$ && "$iters" =~ ^[0-9]+$ && "$warmup" =~ ^[0-9]+$ \
             && "$samples" =~ ^[1-9][0-9]*$ && ( "$expect" == - || "$expect" =~ ^[0-9]+$ ) ]]; then
    echo "$CONF:$lineno: malformed entry: $line" >&2; exit 1
  fi
  for existing in ${NAMES[@]+"${NAMES[@]}"}; do
    [[ "$existing" == "$name" ]] && { echo "$CONF:$lineno: duplicate name $name" >&2; exit 1; }
  done
  if [[ ${#FILTER[@]} -gt 0 && " ${FILTER[*]} " != *" $name "* ]]; then continue; fi
  [[ -f "$HERE/build/$wasm" ]] || { echo "$CONF:$lineno: missing build/$wasm -- run ./setup.sh" >&2; exit 1; }
  NAMES+=("$name"); WASMS+=("$wasm"); PARAMS+=("$param"); ITERS+=("$iters")
  WARMUPS+=("$warmup"); SAMPLES+=("$samples")
  [[ "$expect" == - ]] && expect=""
  CHECKSUMS+=("$expect")
done < "$CONF"
for wanted in ${FILTER[@]+"${FILTER[@]}"}; do
  [[ " ${NAMES[*]:-} " == *" $wanted "* ]] || { echo "BENCHES: $wanted is not in $CONF" >&2; exit 2; }
done
[[ ${#NAMES[@]} -gt 0 ]] || { echo "no benchmarks selected" >&2; exit 1; }

# set_an_args MODE: sets AN_ARGS to the micro-host flags for a mode.
set_an_args() {
  AN_ARGS=()
  if [[ "$1" == an ]]; then
    AN_ARGS=(--an)
    if [[ -n "${AN_CONSTANT:-}" ]]; then AN_ARGS+=(--an-constant "$AN_CONSTANT"); fi
  fi
}

# write_meta FILE [EXTRA]: records the environment of a run.
write_meta() {
  {
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host: $(uname -a)"
    echo "an-benchmark: $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)$(git -C "$ROOT" diff --quiet 2>/dev/null || echo ' (dirty)')"
    echo "wasmtime-an: $(git -C "$ROOT/deps/wasmtime-an" rev-parse HEAD 2>/dev/null || echo unknown)$(git -C "$ROOT/deps/wasmtime-an" diff --quiet 2>/dev/null || echo ' (dirty)')"
    echo "modes: ${MODES[*]}  an_constant: ${AN_CONSTANT:-default}"
    [[ -n "${2:-}" ]] && echo "$2"
    echo "registry ($CONF):"
    sed 's/^/  /' "$CONF"
  } > "$1"
}
