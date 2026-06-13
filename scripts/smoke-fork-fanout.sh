#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/smoke-fork-fanout.sh --backend kvm|hvf --kernel Image [options]

Boot the fork-aware smoke initrd, capture one parent spore, fork it into N
children, resume each child on the same host, and assert that each resumed guest
observes unique fork identity plus resume-time volatile parameters. Use a
SporeVM kernel asset with /dev/mem support, for example
`sporevm-arm64-linux-<version>-Image` from buildkite/cleanroom-kernels.

Options:
  --backend kvm|hvf          Hypervisor harness to run
  --kernel Image            aarch64 Linux kernel Image
  --initrd root.cpio        prebuilt fork-aware initrd (default: build one)
  --workdir DIR             work directory (default: mktemp)
  --count N                 number of children to fork/resume (default: 8)
  --mem-mib N               guest memory size (default: 512)
  --snapshot-after-ms N     capture delay before snapshot (default: 3000)
  --resume-seconds N        seconds to let each child run (default: 6)
  --cmdline TEXT            override fresh-boot kernel command line
  --boot-bin PATH           use an already-built boot harness
  --spore-bin PATH          use an already-built spore CLI
  --no-build                do not run zig build steps
  -h, --help                show this help

Example:
  CC="zig cc -target aarch64-linux-musl" scripts/smoke-fork-fanout.sh \
    --backend kvm --kernel /tmp/sporevm-arm64-linux-6.1.155-Image --count 8
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_option_value() {
  local opt="$1"
  local value="${2-}"
  [[ -n "${value}" ]] || die "${opt} requires a value"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

backend=""
kernel=""
initrd=""
workdir=""
count="8"
mem_mib="512"
snapshot_after_ms="3000"
resume_seconds="6"
cmdline=""
boot_bin=""
spore_bin=""
build=1

while (($#)); do
  case "$1" in
    --backend)
      need_option_value "$1" "${2-}"
      backend="${2:-}"
      shift 2
      ;;
    --kernel)
      need_option_value "$1" "${2-}"
      kernel="${2:-}"
      shift 2
      ;;
    --initrd)
      need_option_value "$1" "${2-}"
      initrd="${2:-}"
      shift 2
      ;;
    --workdir)
      need_option_value "$1" "${2-}"
      workdir="${2:-}"
      shift 2
      ;;
    --count)
      need_option_value "$1" "${2-}"
      count="${2:-}"
      shift 2
      ;;
    --mem-mib)
      need_option_value "$1" "${2-}"
      mem_mib="${2:-}"
      shift 2
      ;;
    --snapshot-after-ms)
      need_option_value "$1" "${2-}"
      snapshot_after_ms="${2:-}"
      shift 2
      ;;
    --resume-seconds)
      need_option_value "$1" "${2-}"
      resume_seconds="${2:-}"
      shift 2
      ;;
    --cmdline)
      need_option_value "$1" "${2-}"
      cmdline="${2:-}"
      shift 2
      ;;
    --boot-bin)
      need_option_value "$1" "${2-}"
      boot_bin="${2:-}"
      shift 2
      ;;
    --spore-bin)
      need_option_value "$1" "${2-}"
      spore_bin="${2:-}"
      shift 2
      ;;
    --no-build)
      build=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "${backend}" in
  kvm|hvf) ;;
  *) die "--backend must be kvm or hvf" ;;
esac

[[ -n "${kernel}" ]] || die "--kernel is required"
[[ -f "${kernel}" ]] || die "kernel not found: ${kernel}"

for numeric_value in "${count}" "${mem_mib}" "${snapshot_after_ms}" "${resume_seconds}"; do
  case "${numeric_value}" in
    ''|*[!0-9]*) die "numeric options must be decimal integers" ;;
  esac
done
(( count > 0 )) || die "--count must be greater than zero"

if [[ -z "${workdir}" ]]; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/sporevm-fork-smoke.XXXXXX")"
fi
mkdir -p "${workdir}"

if [[ -z "${boot_bin}" ]]; then
  boot_bin="${repo_root}/zig-out/bin/${backend}-boot"
fi
if [[ -z "${spore_bin}" ]]; then
  spore_bin="${repo_root}/zig-out/bin/spore"
fi
if [[ -z "${initrd}" ]]; then
  initrd="${workdir}/fork-smoke.cpio"
fi

build_all() {
  if [[ "${build}" == "0" ]]; then
    return
  fi
  if command -v mise >/dev/null 2>&1; then
    (cd "${repo_root}" && mise exec -- zig build)
    (cd "${repo_root}" && mise exec -- zig build "${backend}-boot")
  else
    (cd "${repo_root}" && zig build)
    (cd "${repo_root}" && zig build "${backend}-boot")
  fi
}

safe_remove() {
  local path="$1"
  [[ -n "${path}" ]] || die "empty path"
  [[ "${path}" != "/" ]] || die "refusing to remove /"
  rm -rf "${path}"
}

print_tail() {
  local log="$1"
  echo "--- ${log} tail ---" >&2
  tail -120 "${log}" >&2 || true
  echo "--- end tail ---" >&2
}

run_with_deadline() {
  local seconds="$1"
  local log="$2"
  shift 2

  : >"${log}"
  "$@" >"${log}" 2>&1 &
  local pid="$!"
  local marker="__sporevm_deadline_${pid}__"

  (
    sleep "${seconds}"
    if kill -0 "${pid}" >/dev/null 2>&1; then
      printf '\n%s\n' "${marker}" >>"${log}"
      kill -TERM "${pid}" >/dev/null 2>&1 || true
      sleep 2
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
  ) &
  local timer="$!"

  wait "${pid}"
  local status="$?"

  kill "${timer}" >/dev/null 2>&1 || true
  wait "${timer}" >/dev/null 2>&1 || true

  if grep -q "${marker}" "${log}"; then
    return 124
  fi
  return "${status}"
}

field_value() {
  local key="$1"
  local log="$2"
  grep -Eao "${key}=[^[:space:]]+" "${log}" | head -1 | cut -d= -f2-
}

assert_log_contains() {
  local pattern="$1"
  local log="$2"
  if ! grep -qE "${pattern}" "${log}"; then
    print_tail "${log}"
    die "${log} did not match ${pattern}"
  fi
}

build_all

[[ -x "${boot_bin}" ]] || die "boot harness not executable: ${boot_bin}"
[[ -x "${spore_bin}" ]] || die "spore CLI not executable: ${spore_bin}"

if [[ ! -f "${initrd}" ]]; then
  "${repo_root}/scripts/make-smoke-initrd.sh" --mode fork "${initrd}"
fi
[[ -f "${initrd}" ]] || die "initrd not found: ${initrd}"

parent_spore="${workdir}/parent-spore"
children_dir="${workdir}/children"
safe_remove "${parent_spore}"
safe_remove "${children_dir}"

capture_log="${workdir}/capture.log"
capture_deadline=$(( (snapshot_after_ms + 999) / 1000 + 30 ))
capture_cmd=("${boot_bin}" "${kernel}" --mem-mib "${mem_mib}" --initrd "${initrd}" --snapshot-after-ms "${snapshot_after_ms}" --spore "${parent_spore}")
if [[ -n "${cmdline}" ]]; then
  capture_cmd+=(--cmdline "${cmdline}")
fi

set +e
run_with_deadline "${capture_deadline}" "${capture_log}" "${capture_cmd[@]}"
capture_status="$?"
set -e
if [[ "${capture_status}" != "0" ]]; then
  print_tail "${capture_log}"
  die "capture failed with status ${capture_status}"
fi
[[ -f "${parent_spore}/manifest.json" ]] || die "capture did not write ${parent_spore}/manifest.json"

"${spore_bin}" fork "${parent_spore}" --count "${count}" --out "${children_dir}" >"${workdir}/fork.json"

vm_ids=()
hostnames=()
mac_addresses=()
entropy_seeds=()
resume_times=()

for ((i = 0; i < count; i++)); do
  child_dir="${children_dir}/$(printf '%06d' "${i}")"
  [[ -f "${child_dir}/manifest.json" ]] || die "missing child manifest: ${child_dir}/manifest.json"
  log="${workdir}/child-$(printf '%06d' "${i}").log"
  cmd=("${boot_bin}" "${kernel}" --mem-mib "${mem_mib}" --resume "${child_dir}")

  set +e
  run_with_deadline "${resume_seconds}" "${log}" "${cmd[@]}"
  status="$?"
  set -e
  if [[ "${status}" != "0" && "${status}" != "124" ]]; then
    print_tail "${log}"
    die "child ${i} resume failed with status ${status}"
  fi

  assert_log_contains "sporevm-fork-smoke generation=.*fork_index=${i}.*fork_count=${count}.*irq_status=1" "${log}"
  assert_log_contains "sporevm-fork-smoke vm_id=spore-[0-9a-f]+ hostname=spore-[0-9a-f]+-[0-9]{6} mac_address=([0-9a-f]{2}:){5}[0-9a-f]{2}" "${log}"
  assert_log_contains "resume_time_unix_ns=[1-9][0-9]*" "${log}"
  assert_log_contains "entropy_seed=[0-9a-f]{32}" "${log}"
  assert_log_contains "irq_status_after_ack=0" "${log}"

  vm_ids+=("$(field_value vm_id "${log}")")
  hostnames+=("$(field_value hostname "${log}")")
  mac_addresses+=("$(field_value mac_address "${log}")")
  entropy_seeds+=("$(field_value entropy_seed "${log}")")
  resume_times+=("$(field_value resume_time_unix_ns "${log}")")
  echo "child ok: index=${i} vm_id=${vm_ids[-1]} hostname=${hostnames[-1]} log=${log}"
done

unique_count() {
  printf '%s\n' "$@" | LC_ALL=C sort -u | wc -l | tr -d ' '
}

[[ "$(unique_count "${vm_ids[@]}")" == "${count}" ]] || die "vm_id values were not unique"
[[ "$(unique_count "${hostnames[@]}")" == "${count}" ]] || die "hostname values were not unique"
[[ "$(unique_count "${mac_addresses[@]}")" == "${count}" ]] || die "mac_address values were not unique"
[[ "$(unique_count "${entropy_seeds[@]}")" == "${count}" ]] || die "entropy_seed values were not unique"

echo "fork fan-out ok: backend=${backend} count=${count} workdir=${workdir}"
