#! /bin/bash
#
# The goal is to launch (MPTCP) kernel selftests and more.
# But also to provide a dev env for kernel developers or testers.
#
# Arguments:
#   - "manual": to have a console in the VM. Additional args are for the kconfig
#   - args we pass to kernel's "scripts/config" script.

# We should manage all errors in this script
set -e

is_ci() {
	[ "${CI}" = "true" ]
}

trace_needed() {
	is_ci || [ "${INPUT_TRACE}" = "1" ]
}

set_trace_on() {
	if trace_needed; then
		set -x
	fi
}

set_trace_off() {
	if trace_needed; then
		set +x
	fi
}

set_trace_on

# The behaviour can be changed with 'input' env var
: "${INPUT_CCACHE_MAXSIZE:=5G}"
: "${INPUT_NO_BLOCK:=0}"
: "${INPUT_PACKETDRILL_NO_SYNC:=0}"
: "${INPUT_PACKETDRILL_NO_MORE_TOLERANCE:=0}"
: "${INPUT_PACKETDRILL_STABLE:=0}"
: "${INPUT_RUN_LOOP_CONTINUE:=0}"
: "${INPUT_RUN_TESTS_ONLY:=""}"
: "${INPUT_RUN_TESTS_EXCEPT:=""}"
: "${INPUT_SELFTESTS_DIR:=""}"
: "${INPUT_SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES:=1}"
: "${INPUT_SELFTESTS_MPTCP_LIB_COLOR_FORCE:=1}"
: "${INPUT_CPUS:=""}"
: "${INPUT_CI_RESULTS_DIR:=""}"
: "${INPUT_CI_PRINT_EXIT_CODE:=1}"
: "${INPUT_EXPECT_TIMEOUT:="-1"}"

: "${PACKETDRILL_GIT_BRANCH:=mptcp-net-next}"
: "${CI_TIMEOUT_SEC:=5400}"
: "${VIRTME_ARCH:=x86_64}"

TIMESTAMPS_SEC_START=$(date +%s)
# CI only: estimated time before (clone) and after (artifacts) running this script
VIRTME_EXPECT_TIMEOUT="480"

KERNEL_SRC="${PWD}"

VIRTME_WORKDIR="${KERNEL_SRC}/.virtme"
VIRTME_BUILD_DIR="${VIRTME_WORKDIR}/build"
VIRTME_SCRIPTS_DIR="${VIRTME_WORKDIR}/scripts"
VIRTME_PERF_DIR="${VIRTME_BUILD_DIR}/tools/perf"

VIRTME_KCONFIG="${VIRTME_BUILD_DIR}/.config"

VIRTME_SCRIPT="${VIRTME_SCRIPTS_DIR}/tests.sh"
VIRTME_SCRIPT_END="__VIRTME_END__"
VIRTME_RUN_SCRIPT="${VIRTME_SCRIPTS_DIR}/virtme.sh"
VIRTME_RUN_EXPECT="${VIRTME_SCRIPTS_DIR}/virtme.expect"

SELFTESTS_DIR="${INPUT_SELFTESTS_DIR:-tools/testing/selftests/net/mptcp}"
SELFTESTS_CONFIG="${SELFTESTS_DIR}/config"

export CCACHE_MAXSIZE="${INPUT_CCACHE_MAXSIZE}"
export CCACHE_DIR="${VIRTME_WORKDIR}/ccache"

export KBUILD_OUTPUT="${VIRTME_BUILD_DIR}"
export KCONFIG_CONFIG="${VIRTME_KCONFIG}"

mkdir -p \
	"${VIRTME_BUILD_DIR}" \
	"${VIRTME_SCRIPTS_DIR}" \
	"${VIRTME_PERF_DIR}" \
	"${CCACHE_DIR}"

VIRTME_PROG_PATH="/opt/virtme"
VIRTME_CONFIGKERNEL="${VIRTME_PROG_PATH}/virtme-configkernel"
VIRTME_RUN="${VIRTME_PROG_PATH}/virtme-run"
VIRTME_RUN_OPTS=(--arch "${VIRTME_ARCH}" --net --memory 2048M --kdir "${VIRTME_BUILD_DIR}" --mods=auto --rwdir "." --pwd --show-command)
VIRTME_RUN_OPTS+=(--kopt mitigations=off)

# results dir
RESULTS_DIR_BASE="${VIRTME_WORKDIR}/results"
RESULTS_DIR=

# log files
OUTPUT_VIRTME=
TESTS_SUMMARY=
CONCLUSION=
KMEMLEAK=

EXIT_STATUS=0
EXIT_REASONS=()
EXIT_TITLE="KVM Validation"
EXPECT=0
VIRTME_EXEC_RUN="${KERNEL_SRC}/.virtme-exec-run"
VIRTME_EXEC_PRE="${KERNEL_SRC}/.virtme-exec-pre"
VIRTME_EXEC_POST="${KERNEL_SRC}/.virtme-exec-post"
VIRTME_PREPARE_POST="${KERNEL_SRC}/.virtme-prepare-post"

COLOR_RED="\E[1;31m"
COLOR_GREEN="\E[1;32m"
COLOR_BLUE="\E[1;34m"
COLOR_RESET="\E[0m"

# $1: color, $2: text
print_color() {
	echo -e "${START_PRINT:-}${*}${COLOR_RESET}"
}

print() {
	print_color "${COLOR_GREEN}${*}"
}

printinfo() {
	print_color "${COLOR_BLUE}${*}"
}

printerr() {
	print_color "${COLOR_RED}${*}" >&2
}

setup_env() {
	# Avoid 'unsafe repository' error: we need to get the rev/tag later from
	# this docker image
	git config --global --add safe.directory "${KERNEL_SRC}"

	if is_ci; then
		# Root dir: not to have to go down dirs to get artifacts
		RESULTS_DIR="${KERNEL_SRC}${INPUT_CI_RESULTS_DIR:+/${INPUT_CI_RESULTS_DIR}}"
		mkdir -p "${RESULTS_DIR}"

		VIRTME_RUN_OPTS+=(--cpus "${INPUT_CPUS:-$(nproc)}")

		EXIT_TITLE="${EXIT_TITLE}: ${mode}" # only one mode

		if [ -n "${INPUT_RUN_TESTS_ONLY}" ]; then
			EXIT_TITLE="${EXIT_TITLE} (only ${INPUT_RUN_TESTS_ONLY})"
		fi

		if [ -n "${INPUT_RUN_TESTS_EXCEPT}" ]; then
			EXIT_TITLE="${EXIT_TITLE} (except ${INPUT_RUN_TESTS_EXCEPT})"
		fi
	else
		# avoid override
		RESULTS_DIR="${RESULTS_DIR_BASE}/$(git rev-parse --short HEAD)/${mode}"
		rm -rf "${RESULTS_DIR}"
		mkdir -p "${RESULTS_DIR}"

		VIRTME_RUN_OPTS+=(--cpus "${INPUT_CPUS:-2}") # limit to 2 cores for now
	fi

	OUTPUT_VIRTME="${RESULTS_DIR}/output.log"
	TESTS_SUMMARY="${RESULTS_DIR}/summary.txt"
	CONCLUSION="${RESULTS_DIR}/conclusion.txt"
	KMEMLEAK="${RESULTS_DIR}/kmemleak.txt"
}

_get_last_iproute_version() {
	curl https://git.kernel.org/pub/scm/network/iproute2/iproute2.git/refs/tags 2>/dev/null | \
		grep "/tag/?h=v[0-9]" | \
		cut -d\' -f2 | cut -d= -f2 | \
		sort -Vu | \
		tail -n1
}

check_last_iproute() { local last curr
	# only check on CI
	if ! is_ci; then
		return 0
	fi

	# skip the check for stable, fine not to have the latest version
	if [ "${INPUT_PACKETDRILL_STABLE}" = "1" ]; then
		return 0
	fi

	printinfo "Check IPRoute2 version"

	last="$(_get_last_iproute_version)"

	if [[ "${IPROUTE2_GIT_SHA}" == "v"* ]]; then
		curr="${IPROUTE2_GIT_SHA}"
		if [ "${curr}" = "${last}" ]; then
			printinfo "IPRoute2: using the last version: ${last}"
		else
			printerr "WARN: IPRoute2: not the last version: ${curr} < ${last}"
		fi
	else
		printerr "TODO: check ip -V"
		exit 1
	fi

}

_check_source_exec_one() {
	local src="${1}"
	local reason="${2}"

	if [ -f "${src}" ]; then
		printinfo "This script file exists and will be used ${reason}: $(basename "${src}")"
		cat -n "${src}"

		if is_ci || [ "${INPUT_NO_BLOCK}" = "1" ]; then
			printinfo "Check source exec: not blocking"
		else
			print "Press Enter to continue (use 'INPUT_NO_BLOCK=1' to avoid this)"
			read -r
		fi
	fi
}

check_source_exec_all() {
	printinfo "Check extented exec files"

	_check_source_exec_one "${VIRTME_EXEC_PRE}" "before the tests suite"
	_check_source_exec_one "${VIRTME_EXEC_RUN}" "to replace the execution of the whole tests suite"
	_check_source_exec_one "${VIRTME_EXEC_POST}" "after the tests suite"
}

_make() {
	make -j"$(nproc)" -l"$(nproc)" "${@}"
}

_make_o() {
	_make O="${VIRTME_BUILD_DIR}" "${@}"
}

# $1: source ; $2: target
_add_symlink() {
	local src="${1}"
	local dst="${2}"

	if [ -e "${dst}" ] && [ ! -L "${dst}" ]; then
		printerr "${dst} already exists and is not a symlink, please remove it"
		return 1
	fi

	ln -sf "${src}" "${dst}"
}

# $@: extra kconfig
gen_kconfig() { local mode kconfig=()
	mode="${1}"
	shift

	printinfo "Generate kernel config"

	if [ "${mode}" = "debug" ]; then
		kconfig+=(
			-e NET_NS_REFCNT_TRACKER # useful for 'net' tests
			-d SLUB_DEBUG_ON # perf impact is too important
			-e BOOTPARAM_SOFTLOCKUP_PANIC # instead of blocking
			-e BOOTPARAM_HUNG_TASK_PANIC # instead of blocking
		)

		_make_o defconfig debug.config
	else
		# low-overhead sampling-based memory safety error detector.
		# Only in non-debug: KASAN is more precise
		kconfig+=(-e KFENCE)

		_make_o defconfig "${VIRTME_ARCH}_defconfig"
	fi

	# Debug info for developers
	kconfig+=(-e DEBUG_INFO -e DEBUG_INFO_DWARF4 -e GDB_SCRIPTS)

	# Compressed (old/new option)
	kconfig+=(-e DEBUG_INFO_COMPRESSED -e DEBUG_INFO_COMPRESSED_ZLIB)

	# We need more debug info but it is slow to generate
	if [ "${mode}" = "btf" ]; then
		kconfig+=(-e DEBUG_INFO_BTF)
	elif is_ci || [ "${mode}" != "debsym" ]; then
		kconfig+=(-e DEBUG_INFO_REDUCED -e DEBUG_INFO_SPLIT)
	fi

	# Debug tools for developers
	kconfig+=(
		-e DYNAMIC_DEBUG --set-val CONSOLE_LOGLEVEL_DEFAULT 8
		-e FTRACE -e FUNCTION_TRACER -e DYNAMIC_FTRACE
		-e FTRACE_SYSCALLS -e HIST_TRIGGERS
	)

	# Extra sanity checks in networking: for the moment, small checks
	kconfig+=(-e DEBUG_NET)

	# Extra options needed for MPTCP KUnit tests
	kconfig+=(-m KUNIT -e KUNIT_DEBUGFS -d KUNIT_ALL_TESTS -m MPTCP_KUNIT_TEST)

	# Options for BPF
	kconfig+=(-e BPF_JIT -e BPF_SYSCALL)

	# Extra options needed for packetdrill
	# note: we still need SHA1 for fallback tests with v0
	kconfig+=(-e TUN -e CRYPTO_USER_API_HASH -e CRYPTO_SHA1)

	# Useful to reproduce issue
	kconfig+=(-e NET_SCH_TBF)

	# Disable retpoline to accelerate tests
	kconfig+=(-d RETPOLINE)

	# Disable components we don't need
	kconfig+=(
		-d PCCARD -d MACINTOSH_DRIVERS -d SOUND -d USB_SUPPORT
		-d NEW_LEDS -d SURFACE_PLATFORMS -d DRM -d FB
	)

	# extra config
	kconfig+=("${@}")

	# KBUILD_OUTPUT is used by virtme
	"${VIRTME_CONFIGKERNEL}" --arch "${VIRTME_ARCH}" --update

	# Extra options are needed for kselftests
	./scripts/kconfig/merge_config.sh -m "${VIRTME_KCONFIG}" "${SELFTESTS_CONFIG}"

	./scripts/config --file "${VIRTME_KCONFIG}" "${kconfig[@]}"

	_make_o olddefconfig

	if is_ci; then
		# Useful to help reproducing issues later
		zstd -19 -T0 "${VIRTME_KCONFIG}" -o "${RESULTS_DIR}/config.zstd"
	fi
}

build_kernel() {
	# undo BPFTrace and cie workaround
	find "${VIRTME_BUILD_DIR}/include" \
		-mindepth 1 -maxdepth 1 \
		! -name 'config' ! -name 'generated' \
		-type d -exec rm -r {} +

	_make_o

	# for BPFTrace and cie
	cp -r include/ "${VIRTME_BUILD_DIR}"

	_make_o headers_install INSTALL_HDR_PATH="${VIRTME_BUILD_DIR}"
}

build_modules() {
	_make_o modules

	# virtme will mount a tmpfs there + symlink to .virtme_mods
	mkdir -p /lib/modules
}

build_perf() {
	if [ "${INPUT_BUILD_SKIP_PERF}" = 1 ]; then
		printinfo "Skip perf build"
		return 0
	fi

	cd tools/perf

	_make O="${VIRTME_PERF_DIR}" DESTDIR=/usr install

	cd "${KERNEL_SRC}"
}

build() {
	if [ "${INPUT_BUILD_SKIP}" = 1 ]; then
		printinfo "Skip kernel build"
		return 0
	fi

	printinfo "Build the kernel"

	build_kernel
	build_modules
	build_perf
}

build_selftests() {
	if [ "${INPUT_BUILD_SKIP_SELFTESTS}" = 1 ]; then
		printinfo "Skip selftests build"
		return 0
	fi

	_make_o KHDR_INCLUDES="-I${VIRTME_BUILD_DIR}/include" -C "${SELFTESTS_DIR}"
}

build_packetdrill() { local old_pwd kversion kver_maj kver_min branch
	if [ "${INPUT_BUILD_SKIP_PACKETDRILL}" = 1 ]; then
		printinfo "Skip Packetdrill build"
		return 0
	fi

	old_pwd="${PWD}"

	# make sure we have the last stable tests
	cd /opt/packetdrill/
	if [ "${INPUT_PACKETDRILL_NO_SYNC}" = "1" ]; then
		printinfo "Packetdrill: no sync"
	else
		git fetch origin

		branch="${PACKETDRILL_GIT_BRANCH}"
		if [ "${INPUT_PACKETDRILL_STABLE}" = "1" ]; then
			kversion=$(make -C "${KERNEL_SRC}" -s kernelversion) ## 5.17.0 or 5.17.0-rc8
			kver_maj=${kversion%%.*} ## 5
			kver_min=${kversion#*.} ## 17.0*
			kver_mic=${kver_min#*.} ## 0
			kver_min=${kver_min%%.*} ## 17

			# without rc, it means we probably already merged with net-next
			if [[ ! "${kversion}" =~ rc ]] && [ "${kver_mic}" = 0 ]; then
				kver_min=$((kver_min + 1))

				# max .19 because Linus has 20 fingers
				if [ ${kver_min} -gt 19 ]; then
					kver_maj=$((kver_maj + 1))
					kver_min=0
				fi
			fi

			kversion="mptcp-${kver_maj}.${kver_min}"
			# set the new branch only if it exists. If not, take the dev one
			if git show-ref --quiet "refs/remotes/origin/${kversion}"; then
				branch="${kversion}"
			fi
		fi
		git checkout -f "origin/${branch}"
	fi
	cd gtests/net/packetdrill/
	./configure
	_make

	cd ../mptcp
	if [ "${INPUT_PACKETDRILL_NO_MORE_TOLERANCE}" = "1" ]; then
		printinfo "Packetdrill: not modifying the tolerance"
	else
		# reduce debug logs: too much
		set_trace_off

		local pf val new_val
		for pf in $(git grep -l "^--tolerance_usecs="); do
			# shellcheck disable=SC2013 # to filter duplicated ones
			for val in $(grep "^--tolerance_usecs=" "${pf}" | cut -d= -f2 | sort -u); do
				if [ "${mode}" = "debug" ]; then
					# Add higher tolerance in debug mode:
					# the environment can be very slow
					new_val=$((val * 10))
				else
					# double the time in normal mode:
					# public CI can be quite loaded...
					new_val=$((val * 4))
				fi

				sed -i "s/^--tolerance_usecs=${val}$/--tolerance_usecs=${new_val}/g" "${pf}"
			done
		done

		set_trace_on
	fi
	cd "${old_pwd}"
}

prepare_hosts_file() {
	# To fix: sudo: unable to resolve host (none): Name or service not known
	echo "127.0.1.1 (none)" >> /etc/hosts
}

prepare() { local mode no_tap=1
	mode="${1}"

	printinfo "Prepare the environment"

	build_selftests
	build_packetdrill
	prepare_hosts_file

	is_ci && no_tap=0

	cat <<EOF > "${VIRTME_SCRIPT}"
#! /bin/bash -x

# useful for virtme-exec-run
TAP_PREFIX="${KERNEL_SRC}/tools/testing/selftests/kselftest/prefix.pl"
RESULTS_DIR="${RESULTS_DIR}"
OUTPUT_VIRTME="${OUTPUT_VIRTME}"
KUNIT_CORE_LOADED=0
export SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES="${INPUT_SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES}"
export SELFTESTS_MPTCP_LIB_COLOR_FORCE="${INPUT_SELFTESTS_MPTCP_LIB_COLOR_FORCE}"
export SELFTESTS_MPTCP_LIB_NO_TAP="${no_tap}"

# \$1: name of the test
_can_run() { local tname
	tname="\${1}"

	# only some tests?
	if [ -n "${INPUT_RUN_TESTS_ONLY}" ]; then
		if ! echo "${INPUT_RUN_TESTS_ONLY}" | grep -wq "\${tname}"; then
			return 1
		fi
	fi

	# not some tests?
	if [ -n "${INPUT_RUN_TESTS_EXCEPT}" ]; then
		if echo "${INPUT_RUN_TESTS_EXCEPT}" | grep -wq "\${tname}"; then
			return 1
		fi
	fi

	return 0
}

can_run() {
	# Use the function name of the caller without the prefix
	_can_run "\${FUNCNAME[1]#*_}"
}

# \$1: file ; \$2+: commands
_tap() { local out out_subtests tmp fname rc
	out="\${1}.tap"
	out_subtests="\${1}_subtests.tap"
	shift

	rm -f "\${out}" "\${out_subtests}"
	# With TAP, we have first the summary, then the diagnostic
	tmp="\${out}.tmp"
	fname="\$(basename \${out})"

	# init
	{
		echo "TAP version 13"
		echo "1..1"
	} | tee "\${out}"

	# Exec the command and pipe in tap prefix + store for later
	"\${@}" 2>&1 | "\${TAP_PREFIX}" | tee "\${tmp}"
	# output to stdout now to see the progression
	rc=\${PIPESTATUS[0]}

	# summary
	{
		case \${rc} in
			0)
				echo "ok 1 test: \${fname}"
				;;
			4)
				if [ "\${SELFTESTS_MPTCP_LIB_EXPECT_ALL_FEATURES}" = "1" ]; then
					echo "not ok 1 test: \${fname} # exit=\${rc}"
				else
					echo "ok 1 test: \${fname} # SKIP"
				fi
				;;
			*)
				echo "not ok 1 test: \${fname} # exit=\${rc}"
				;;
		esac
	} | tee -a "\${out}"

	# diagnostic at the end with TAP
	# Strip colours: https://stackoverflow.com/a/18000433
	# Also extract subtests displayed at the end, if any, in a different file without "#"
	sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2};?)?)?[mGK]//g" "\${tmp}" | \
		awk "BEGIN { subtests=0 } {
			if (subtests == 0 && \\\$0 ~ /^# TAP version /) { subtests=1 };
			if (subtests == 0) { print >> \"\${out}\" }
			else { for (i=2; i <= NF; i++) printf(\"%s\", ((i>2) ? OFS : \"\") \\\$i) >> \"\${out_subtests}\" ; printf(\"\n\") >> \"\${out_subtests}\" }
		}"
	rm -f "\${tmp}"

	return \${rc}
}

# \$1: kunit path ; \$2: kunit test
_kunit_result() {
	if ! grep -q "^KTAP" "\${1}" 2>/dev/null; then
		echo "TAP version 14"
		echo "1..1"
	fi

	if ! cat "\${1}"; then
		echo "not ok 1 test: no kunit result \${2} # exit=1"
		return 1
	fi
}

run_kunit_core() {
	[ "\${KUNIT_CORE_LOADED}" = 1 ] && return 0

	_tap "${RESULTS_DIR}/kunit" insmod ${VIRTME_BUILD_DIR}/lib/kunit/kunit.ko
	KUNIT_CORE_LOADED=1
}

# \$1: .ko path
run_kunit_one() { local ko kunit kunit_path
	ko="\${1}"

	kunit="\${ko#${VIRTME_BUILD_DIR}/}" # remove abs dir
	kunit="\${kunit:10:-8}" # remove net/mptcp (10) + _test.ko (8)
	kunit="\${kunit//_/-}" # dash
	kunit_path="/sys/kernel/debug/kunit/\${kunit}/results"

	run_kunit_core || return \${?}

	insmod "\${ko}" || true # errors will also be visible below: no results
	_kunit_result "\${kunit_path}" "\${kunit}" | tee "${RESULTS_DIR}/kunit_\${kunit}.tap"
}

run_kunit_all() { local ko rc=0
	can_run || return 0

	cd "${KERNEL_SRC}"

	for ko in ${VIRTME_BUILD_DIR}/net/mptcp/*_test.ko; do
		run_kunit_one "\${ko}" || rc=\${?}
	done

	return \${rc}
}

# \$1: output tap file; rest: command to launch
_run_selftest_one_tap() {
	cd "${KERNEL_SRC}/${SELFTESTS_DIR}"
	_tap "\${@}"
}

# \$1: script file; rest: command to launch
run_selftest_one() { local sf tap
	sf=\$(basename \${1})
	tap=selftest_\${sf:0:-3}
	shift

	_can_run "\${tap}" || return 0

	_run_selftest_one_tap "${RESULTS_DIR}/\${tap}" "./\${sf}" "\${@}"
}

run_selftest_all() { local sf rc=0
	# The following command re-do a slow headers install + compilation in a different dir
	#make O="${VIRTME_BUILD_DIR}" --silent -C tools/testing/selftests TARGETS=net/mptcp run_tests

	for sf in "${KERNEL_SRC}/${SELFTESTS_DIR}/"*.sh; do
		if [ -x "\${sf}" ]; then
			run_selftest_one "\${sf}" || rc=\${?}
		fi
	done

	return \${rc}
}

_run_mptcp_connect_opt() { local t="\${1}"
	shift

	_run_selftest_one_tap "${RESULTS_DIR}/mptcp_connect_\${t}" ./mptcp_connect.sh "\${@}"
}

run_mptcp_connect_mmap() {
	can_run || return 0

	_run_mptcp_connect_opt mmap -m mmap
}

# \$1: pktd_dir (e.g. mptcp/dss)
run_packetdrill_one() { local pktd_dir pktd tap
	pktd_dir="\${1}"
	pktd="\${pktd_dir#*/}"
	tap="packetdrill_\${pktd//\//_}"

	if [ "\${pktd}" = "common" ]; then
		return 0
	fi

	_can_run "\${tap}" || return 0

	cd /opt/packetdrill/gtests/net/
	PYTHONUNBUFFERED=1 _tap "${RESULTS_DIR}/\${tap}" \
		./packetdrill/run_all.py -l -v \${pktd_dir}
}

run_packetdrill_all() { local pktd_dir rc=0
	cd /opt/packetdrill/gtests/net/

	# dry run just to "heat" up the environment: the first tests are always
	# slower, especially with a debug kernel
	./packetdrill/run_all.py mptcp/add_addr/add_addr4_server.pkt &>/dev/null || true

	for pktd_dir in mptcp/*; do
		run_packetdrill_one "\${pktd_dir}" || rc=\${?}
	done

	return \${rc}
}

run_all() {
	run_kunit_all
	run_selftest_all
	run_mptcp_connect_mmap
	run_packetdrill_all
}

has_call_trace() {
	grep -q "[C]all Trace:" "${OUTPUT_VIRTME}"
}

kmemleak_scan() {
	if [ "${mode}" = "debug" ]; then
		echo scan > /sys/kernel/debug/kmemleak
		cat /sys/kernel/debug/kmemleak > "${KMEMLEAK}"
	fi
}

# \$1: max iterations (<1 means no limit) ; args: what needs to be executed
run_loop_n() { local i tdir rc=0
	n=\${1}
	shift

	tdir="${KERNEL_SRC}/${SELFTESTS_DIR}"
	if ls "\${tdir}/"*.pcap &>/dev/null; then
		mkdir -p "\${tdir}/pcaps"
		mv "\${tdir}/"*.pcap "\${tdir}/pcaps"
	fi

	i=1
	while true; do
		echo -e "\n\n\t=== Attempt: \${i} (\$(date -R)) ===\n\n"

		if ! "\${@}" || has_call_trace; then
			rc=1

			echo -e "\n\n\t=== ERROR after \${i} attempts (\$(date -R)) ===\n\n"

			if [ "${INPUT_RUN_LOOP_CONTINUE}" = "1" ]; then
				echo "Attempt: \${i}" >> "${CONCLUSION}.failed"
			else
				break
			fi
		fi

		rm -f "\${tdir}/"*.pcap 2>/dev/null

		if [ "\${i}" = "\${n}" ]; then
			break
		fi

		i=\$((i+1))
	done

	echo -e "\n\n\tStopped after \${i} attempts\n\n"

	return "\${rc}"
}

# args: what needs to be executed
run_loop() {
	run_loop_n 0 "\${@}"
}

# To run commands before executing the tests
if [ -f "${VIRTME_EXEC_PRE}" ]; then
	source "${VIRTME_EXEC_PRE}"
	# e.g.:
	# echo "file net/mptcp/* +fmp" > /sys/kernel/debug/dynamic_debug/control
	# echo __mptcp_subflow_connect > /sys/kernel/tracing/set_graph_function
	# echo printk > /sys/kernel/tracing/set_graph_notrace
	# echo function_graph > /sys/kernel/tracing/current_tracer
fi

# To exec different tests than the full suite
if [ -f "${VIRTME_EXEC_RUN}" ]; then
	echo -e "\n\n\tNot running all tests but:\n\n-------- 8< --------\n\$(sed "s/#.*//g;/^\s*$/d" "${VIRTME_EXEC_RUN}")\n-------- 8< --------\n\n"
	source "${VIRTME_EXEC_RUN}"
	# e.g.:
	# run_selftest_one ./mptcp_join.sh -f
	# run_loop run_selftest_one ./simult_flows.sh
	# run_packetdrill_one mptcp/dss
else
	run_all
fi

cd "${KERNEL_SRC}"

kmemleak_scan

# To run commands before executing the tests
if [ -f "${VIRTME_EXEC_POST}" ]; then
	source "${VIRTME_EXEC_POST}"
	# e.g.: cat /sys/kernel/tracing/trace
fi

# end
echo "${VIRTME_SCRIPT_END}"
EOF
	chmod +x "${VIRTME_SCRIPT}"

	if [ -f "${VIRTME_PREPARE_POST}" ]; then
		# shellcheck source=/dev/null
		source "${VIRTME_PREPARE_POST}"
	fi
}

run() {
	printinfo "Run the virtme script: manual"

	"${VIRTME_RUN}" "${VIRTME_RUN_OPTS[@]}"
}

run_expect() {
	local timestamps_sec_stop

	if is_ci; then
		timestamps_sec_stop=$(date +%s)

		# max - compilation time - before/after script
		VIRTME_EXPECT_TIMEOUT=$((CI_TIMEOUT_SEC - (timestamps_sec_stop - TIMESTAMPS_SEC_START) - VIRTME_EXPECT_TIMEOUT))
	else
		# disable timeout
		VIRTME_EXPECT_TIMEOUT="${INPUT_EXPECT_TIMEOUT}"
	fi

	printinfo "Run the virtme script: expect (timeout: ${VIRTME_EXPECT_TIMEOUT})"

	cat <<EOF > "${VIRTME_RUN_SCRIPT}"
#! /bin/bash -x
"${VIRTME_RUN}" ${VIRTME_RUN_OPTS[@]} 2>&1 | tr -d '\r'
EOF
	chmod +x "${VIRTME_RUN_SCRIPT}"

	cat <<EOF > "${VIRTME_RUN_EXPECT}"
#!/usr/bin/expect -f

set timeout "${VIRTME_EXPECT_TIMEOUT}"

spawn "${VIRTME_RUN_SCRIPT}"

expect "virtme-init: console is ttyS0\r"
send -- "stdbuf -oL ${VIRTME_SCRIPT}\r"

expect {
	"${VIRTME_SCRIPT_END}\r" {
		send_user "validation script ended with success\n"
	} timeout {
		send_user "Timeout: sending Ctrl+C\n"
		send "\x03\r"
		sleep 2
		send "\x03\r"
	} eof {
		send_user "Unexpected stop of the VM\n"
		exit 1
	}
}
send -- "/usr/lib/klibc/bin/poweroff\r"

expect eof
EOF
	chmod +x "${VIRTME_RUN_EXPECT}"

	# for an unknown reason, we cannot use "--script-sh", qemu is not
	# started, no debug. As a workaround, we use expect.
	"${VIRTME_RUN_EXPECT}" | tee "${OUTPUT_VIRTME}"
}

_get_selftests_gen_files() {
	grep TEST_GEN_FILES "${SELFTESTS_DIR}/Makefile" | cut -d= -f2
}

ccache_stat() {
	if is_ci; then
		ccache -s
	fi
}

# $1: category ; $2: mode ; $3: reason
_register_issue() { local msg
	# only one mode in CI mode
	if is_ci; then
		msg="${1}: ${3}"
	else
		msg="${1} ('${2}' mode): ${3}"
	fi

	if [ "${#EXIT_REASONS[@]}" -eq 0 ]; then
		EXIT_REASONS=("${msg}")
	else
		EXIT_REASONS+=("-" "${msg}")
	fi
}

_had_issues() {
	[ ${#EXIT_REASONS[@]} -gt 0 ]
}

_had_critical_issues() {
	echo "${EXIT_REASONS[*]}" | grep -q "Critical"
}

# $1: end critical ; $2: end unstable
_print_issues() {
	echo -n "${EXIT_REASONS[*]} "
	if _had_critical_issues; then
		echo "${1}"
	else
		echo "${2}"
	fi
}

_has_call_trace() {
	grep -q "Call Trace:" "${OUTPUT_VIRTME}"
}

_print_line() {
	echo "=========================================="
}

decode_stacktrace() {
	./scripts/decode_stacktrace.sh "${VIRTME_BUILD_DIR}/vmlinux" "${KERNEL_SRC}" "${VIRTME_BUILD_DIR}/.virtme_mods"
}

_print_call_trace_info() {
	echo
	_print_line
	echo "Call Trace:"
	_print_line
	grep --text -C 80 "Call Trace:" "${OUTPUT_VIRTME}" | decode_stacktrace
	_print_line
	echo "Call Trace found"
}

_get_call_trace_status() {
	echo "$(grep -c "Call Trace:" "${OUTPUT_VIRTME}") Call Trace(s)"
}

_has_timed_out() {
	! grep -q "${VIRTME_SCRIPT_END}" "${OUTPUT_VIRTME}"
}

_print_timed_out() {
	echo
	_print_line
	echo "Timeout:"
	_print_line
	tail -n 20 "${OUTPUT_VIRTME}"
	_print_line
	echo "Global Timeout"
}

_has_kmemleak() {
	[ -s "${KMEMLEAK}" ]
}

_print_kmemleak() {
	echo
	_print_line
	echo "KMemLeak:"
	_print_line
	decode_stacktrace < "${KMEMLEAK}"
	_print_line
	echo "KMemLeak detected"
}

# $1: mode, rest: args for kconfig
_print_summary_header() {
	local mode="${1}"
	shift

	echo "== Summary =="
	echo
	echo "Ref: ${CIRRUS_TAG:-$(git describe --tags)}"
	echo "Mode: ${mode}"
	echo "Extra kconfig: ${*:-/}"
	echo
}

# [ $1: .tap file, summary file by default]
_has_failed_tests() {
	grep -q "^not ok " "${1:-${TESTS_SUMMARY}}"
}

_print_tests_result() {
	echo "All tests:"
	grep --no-filename -e "^ok [0-9]\+ test:" -e "^not ok " "${RESULTS_DIR}"/*.tap
}

_print_failed_tests() { local t
	echo
	_print_line
	echo "Failed tests:"
	for t in "${RESULTS_DIR}"/*.tap; do
		if _has_failed_tests "${t}"; then
			_print_line
			echo "- $(basename "${t}"):"
			echo
			grep -v "^ok [0-9]\+ - " "${t}"
		fi
	done
	_print_line
}

_get_failed_tests() {
	# not ok 1 test: selftest_mptcp_join.tap # exit=1
	# we just want the main results, not the detailed ones for the moment
	grep "^not ok [0-9]\+ test: " "${TESTS_SUMMARY}" | \
		awk '{ print $5 }' | \
		sort -u | \
		sed "s/\.tap$//g"
}

_get_failed_tests_status() { local t fails=()
	for t in $(_get_failed_tests); do
		fails+=("${t}")
	done

	echo "${#fails[@]} failed test(s): ${fails[*]}"
}

# $1: mode, rest: args for kconfig
analyze() {
	# reduce log that could be wrongly interpreted
	set +x

	local mode="${1}"
	shift

	printinfo "Analyze results"

	if is_ci; then
		LANG=C tap2junit "${RESULTS_DIR}"/*.tap
	fi

	echo -ne "\n${COLOR_GREEN}"
	_print_summary_header "${mode}" "${@}" | tee "${TESTS_SUMMARY}"
	_print_tests_result | tee -a "${TESTS_SUMMARY}"

	echo -ne "${COLOR_RESET}\n${COLOR_RED}"

	if _has_failed_tests; then
		# no tee, it can be long and less important than critical err
		_print_failed_tests >> "${TESTS_SUMMARY}"
		_register_issue "Unstable" "${mode}" "$(_get_failed_tests_status)"
		EXIT_STATUS=42
	fi

	# look for crashes/warnings
	if _has_call_trace; then
		_print_call_trace_info | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "${mode}" "$(_get_call_trace_status)"
		EXIT_STATUS=1

		if is_ci; then
			zstd -19 -T0 "${VIRTME_BUILD_DIR}/vmlinux" \
			     -o "${RESULTS_DIR}/vmlinux.zstd"
		fi
	fi

	if _has_timed_out; then
		_print_timed_out | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "${mode}" "Global Timeout"
		EXIT_STATUS=1
	fi

	if _has_kmemleak; then
		_print_kmemleak | tee -a "${TESTS_SUMMARY}"
		_register_issue "Critical" "${mode}" "KMemLeak"
		EXIT_STATUS=1
	fi

	echo -ne "${COLOR_RESET}"

	if [ "${EXIT_STATUS}" = "1" ]; then
		echo
		printerr "Critical issue(s) detected, exiting"
		exit 1
	fi
}

# $@: args for kconfig
go_manual() { local mode
	mode="${1}"

	printinfo "Start: manual (${mode})"

	setup_env
	gen_kconfig "${@}"
	build
	prepare "${mode}"
	run
}

# $1: mode ; $2+: args for kconfig
go_expect() { local mode
	mode="${1}"

	printinfo "Start: auto (${mode})"

	EXPECT=1

	setup_env
	ccache_stat
	check_last_iproute
	check_source_exec_all
	gen_kconfig "${@}"
	build
	prepare "${mode}"
	run_expect
	ccache_stat
	analyze "${@}"
}

static_analysis() { local src obj ftmp
	ftmp=$(mktemp)

	for src in net/mptcp/*.c; do
		obj="${src/%.c/.o}"
		if [[ "${src}" = *"_test.mod.c" ]]; then
			continue
		fi

		printinfo "Checking: ${src}"

		touch "${src}"
		if ! KCFLAGS="-Werror" _make_o W=1 "${obj}"; then
			printerr "Found make W=1 issues for ${src}"
		fi

		touch "${src}"
		_make_o C=1 "${obj}" >/dev/null 2>"${ftmp}" || true

		if test -s "${ftmp}"; then
			cat "${ftmp}"
			printerr "Found make C=1 issues for ${src}"
		fi
	done

	rm -f "${ftmp}"
}

print_conclusion() { local rc=${1}
	echo -n "${EXIT_TITLE}: "

	if _had_issues; then
		_print_issues "❌" "🔴"
	elif [ "${rc}" != "0" ]; then
		echo "Script error! ❓"
	else
		echo "Success! ✅"
	fi
}

exit_trap() { local rc=${?}
	set +x

	echo -ne "\n${COLOR_BLUE}"
	if [ "${EXPECT}" = 1 ]; then
		print_conclusion ${rc} | tee "${CONCLUSION:-"conclusion.txt"}"
	fi
	echo -e "${COLOR_RESET}"

	return ${rc}
}

usage() {
	echo "Usage: ${0} <manual-normal | manual-debug | auto-normal | auto-debug | auto-all> [KConfig]"
	echo
	echo " - manual: access to an interactive shell"
	echo " - auto: the tests suite is ran automatically"
	echo
	echo " - normal: without the debug kconfig"
	echo " - debug: with debug kconfig"
	echo " - all: both 'normal' and 'debug'"
	echo
	echo " - KConfig: optional kernel config: arguments for './scripts/config'"
	echo
	echo "Usage: ${0} <make [params] | make.cross [params] | cmd <command> | src <source file>>"
	echo
	echo " - make: run the make command with optional parameters"
	echo " - make.cross: run Intel's make.cross command with optional parameters"
	echo " - cmd: run the given command"
	echo " - src: source a given script file"
	echo
	echo "This script needs to be ran from the root of kernel source code."
	echo
	echo "Some files can be added in the kernel sources to modify the tests suite."
	echo "See the README file for more details."
}


MODE="${1}"
if [ -z "${MODE}" ]; then
	usage
	exit 0
fi
shift

if [ ! -s "${SELFTESTS_CONFIG}" ]; then
	printerr "Please be at the root of kernel source code with MPTCP (Upstream) support"
	exit 1
fi


trap 'exit_trap' EXIT

case "${MODE}" in
	"manual" | "normal" | "manual-normal")
		go_manual "normal" "${@}"
		;;
	"debug" | "manual-debug")
		go_manual "debug" "${@}"
		;;
	"btf" | "manual-btf")
		go_manual "btf" "${@}"
		;;
	"expect-normal" | "auto-normal")
		go_expect "normal" "${@}"
		;;
	"expect-debug" | "auto-debug")
		go_expect "debug" "${@}"
		;;
	"expect-btf" | "auto-btf")
		go_expect "btf" "${@}"
		;;
	"expect" | "all" | "expect-all" | "auto-all")
		# first with the minimum because configs like KASAN slow down the
		# tests execution, it might hide bugs
		_make_o -C "${SELFTESTS_DIR}" clean
		go_expect "normal" "${@}"
		_make_o clean
		go_expect "debug" "${@}"
		;;
	"make")
		_make_o "${@}"
		;;
	"make.cross")
		MAKE_CROSS="/usr/sbin/make.cross"
		wget https://raw.githubusercontent.com/intel/lkp-tests/master/sbin/make.cross -O "${MAKE_CROSS}"
		chmod +x "${MAKE_CROSS}"
		COMPILER_INSTALL_PATH="${VIRTME_WORKDIR}/0day" \
			COMPILER="${COMPILER}" \
				"${MAKE_CROSS}" "${@}"
		;;
	"cmd" | "command")
		"${@}"
		;;
	"src" | "source" | "script")
		if [ ! -f "${1}" ]; then
			printerr "No such file: ${1}"
			exit 1
		fi

		# shellcheck disable=SC1090
		source "${1}"
		;;
	"static" | "static-analysis")
		static_analysis
		;;
	*)
		set +x
		printerr "Unknown mode: ${MODE}"
		echo -e "${COLOR_RED}"
		usage
		echo -e "${COLOR_RESET}"
		exit 1
esac

if is_ci && [ "${INPUT_CI_PRINT_EXIT_CODE}" = 1 ]; then
	echo "==EXIT_STATUS=${EXIT_STATUS}=="
else
	exit "${EXIT_STATUS}"
fi
