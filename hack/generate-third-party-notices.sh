#!/usr/bin/env bash
# Copyright (c) NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Writes THIRD_PARTY_NOTICES.md for everything the deb, rpm and image ship:
# this repository's vendored Go modules, and the Go and C dependencies of the
# libnvidia-container libraries built from the submodule.

set -euo pipefail

# LC_ALL=C on every sort and grep below: collation and case folding must not vary
# by locale (under tr_TR glibc will not fold I to i, so LICENSE stops matching).

OUTPUT="${OUTPUT:-THIRD_PARTY_NOTICES.md}"
LICENSES_DIR="${LICENSES_DIR:-.licenses-cache}"
MULTI_ARCH_MK="${MULTI_ARCH_MK:-deployments/container/multi-arch.mk}"
MODULES_TXT="${MODULES_TXT:-vendor/modules.txt}"

# Exactly what 'make cmds' builds and ships.
PACKAGES=("./cmd/...")

# The image ships the extracted deb and rpm payloads, which carry
# libnvidia-container's shared libraries alongside this repository's own
# commands. Its dependencies are therefore redistributed here and are listed
# below. The submodule is pinned by commit, so a bump shows up as a diff in
# this repository rather than changing silently.
LNC_DIR="${LNC_DIR:-third_party/libnvidia-container}"
LNC_GO_DIR="${LNC_GO_DIR:-${LNC_DIR}/src/nvcgo}"
LNC_MODULES_TXT="${LNC_MODULES_TXT:-${LNC_GO_DIR}/vendor/modules.txt}"
LNC_VENDOR_DIR="${LNC_VENDOR_DIR:-${LNC_GO_DIR}/vendor}"
LNC_PACKAGES=("./...")

# Copyright blocks are scraped out of the C sources actually compiled in;
# elftoolchain and nvidia-modprobe ship no license file of their own.
NOTICE_SOURCE_RE='\.(c|h|m4)$'
BLOCK_SEP='@@@NVIDIA-CONTAINER-TOOLKIT-NOTICE-BLOCK@@@'

# id|makefile|tar members|license files|notice sources|built when|SPDX|location file|location url or reason
C_DEPS=(
    "elftoolchain|${LNC_DIR}/mk/elftoolchain.mk|common libelf||libelf common/_elftc.h common/elfdefinitions.h|WITH_LIBELF=no|BSD-2-Clause AND BSD-3-Clause|none|none in this release; the terms are the per-file notices reproduced below"
    "libtirpc|${LNC_DIR}/mk/libtirpc.mk||COPYING|src tirpc|WITH_TIRPC=yes|BSD-3-Clause|COPYING|https://git.linux-nfs.org/?p=steved/libtirpc.git;a=blob_plain;f=COPYING;hb=refs/tags/libtirpc-\$(VERSION_DASHED)"
    "nvidia-modprobe|${LNC_DIR}/mk/nvidia-modprobe.mk|modprobe-utils||modprobe-utils|always|MIT|none|not the archive's COPYING, which is GPL-2.0 and covers binaries this repository does not ship; the terms are the per-file notices reproduced below"
)

# Must match the released image platforms; verify_platform_matrix fails on
# drift. go-licenses resolves one platform per run, so collection runs per
# target and merges.
PLATFORMS=(
    "linux/amd64"
    "linux/arm64"
)

die() {
    printf 'ERROR: %s\n' "$1" >&2
    shift
    if (( $# > 0 )); then
        printf '%s\n' "$@" >&2
    fi
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

# Licenses that are themselves Markdown close a fixed ``` fence early and invert
# every block after it, so open with one backtick more than the file's longest run.
fence_for() {
    local file="$1" longest_backtick_run fence_width
    # -a: a license containing a NUL byte is otherwise treated as binary and
    # grep prints "Binary file ... matches" rather than the matches themselves.
    longest_backtick_run=$(LC_ALL=C grep -oaE '`+' "${file}" 2>/dev/null \
        | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' || true)
    fence_width=$(( longest_backtick_run + 1 ))
    (( fence_width < 3 )) && fence_width=3
    printf '%*s' "${fence_width}" '' | tr ' ' '`'
}

check_prerequisites() {
    command -v go >/dev/null 2>&1 || die "go is not installed."

    # -x alone is not enough: bin/ is bind-mounted into the build image by the
    # docker-% targets, so a host-built binary is present but not executable there.
    if ./bin/go-licenses --help >/dev/null 2>&1; then
        GO_LICENSES="${PWD}/bin/go-licenses"
    elif command -v go-licenses >/dev/null 2>&1; then
        GO_LICENSES="$(command -v go-licenses)"
    else
        die "go-licenses is not installed." "Install it with 'make bin/go-licenses'."
    fi

    local required_file
    for required_file in "${MULTI_ARCH_MK}" "${MODULES_TXT}" "${LICENSE_OVERRIDES}"; do
        [[ -f "${required_file}" ]] \
            || die "${required_file} not found — run 'make third-party-notices' from the repo root."
    done

    LOCAL_MODULE=$(go list -m 2>/dev/null || true)
    [[ -n "${LOCAL_MODULE}" ]] || die "could not determine local module path via 'go list -m'."

    # CGO must stay on: with CGO_ENABLED=0 the build constraints exclude every
    # file in go-nvml/pkg/dl and internal/cuda, so go-licenses cannot load
    # ./cmd/... at all. No C compiler is needed; go-licenses never compiles.
    export GOFLAGS="-mod=vendor"
    export CGO_ENABLED=1
}

verify_platform_matrix() {
    local expected actual
    expected=$(sed -n 's/^DOCKER_BUILD_PLATFORM_OPTIONS[[:space:]]*?*=[[:space:]]*--platform=//p' \
        "${MULTI_ARCH_MK}" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u)
    [[ -n "${expected}" ]] \
        || die "could not read DOCKER_BUILD_PLATFORM_OPTIONS from ${MULTI_ARCH_MK}."

    actual=$(printf '%s\n' "${PLATFORMS[@]}" | LC_ALL=C sort -u)
    [[ "${expected}" == "${actual}" ]] || die \
        "the PLATFORMS matrix is out of sync with ${MULTI_ARCH_MK}." \
        "Update the PLATFORMS array in hack/generate-third-party-notices.sh to match the released targets." \
        "  matrix (PLATFORMS): $(echo "${actual}" | paste -sd ' ' -)" \
        "  image platforms:    $(echo "${expected}" | paste -sd ' ' -)"
}

prepare_workspace() {
    # Guard the override: '', '/', '.' or '..' would make the rm -rf fatal.
    case "${LICENSES_DIR}" in
        ""|"/"|"."|"..")
            die "refusing to 'rm -rf' unsafe LICENSES_DIR='${LICENSES_DIR}'."
            ;;
    esac
    rm -rf "${LICENSES_DIR}"
    mkdir -p "${LICENSES_DIR}"

    local workspace_template="${TMPDIR:-/tmp}/nvidia-container-toolkit-notices"
    SAVE_ROOT="$(mktemp -d "${workspace_template}.XXXXXX")"
    COMBINED_CSV="$(mktemp "${workspace_template}-csv.XXXXXX")"
    INDEX_FILE="$(mktemp "${workspace_template}-idx.XXXXXX")"
    BUNDLED_CSV="$(mktemp "${workspace_template}-bundled-csv.XXXXXX")"
    BUNDLED_INDEX="$(mktemp "${workspace_template}-bundled-idx.XXXXXX")"
    MERGED_INDEX="$(mktemp "${workspace_template}-merged-idx.XXXXXX")"
    C_INDEX="$(mktemp "${workspace_template}-c-idx.XXXXXX")"
    WORK_DIR="$(mktemp -d "${workspace_template}-work.XXXXXX")"
    mkdir -p "${WORK_DIR}/c"

    # Composed next to OUTPUT, not in TMPDIR, so the publish below is a rename.
    local out_dir
    out_dir="$(dirname "${OUTPUT}")"
    mkdir -p "${out_dir}"
    OUT_TMP="$(mktemp "${out_dir}/.$(basename "${OUTPUT}").XXXXXX")"

    trap 'rm -rf "${SAVE_ROOT}" "${WORK_DIR}"; rm -f "${COMBINED_CSV}" "${INDEX_FILE}" "${BUNDLED_CSV}" "${BUNDLED_INDEX}" "${MERGED_INDEX}" "${C_INDEX}" "${OUT_TMP}"' EXIT
}

collect_runtime() {
    local platform goos goarch save_dir

    for platform in "${PLATFORMS[@]}"; do
        goos="${platform%/*}"
        goarch="${platform#*/}"
        log "Collecting licenses for ${goos}/${goarch}..."

        save_dir="${SAVE_ROOT}/${goos}_${goarch}"

        # Only the local module: --ignore matches raw string prefixes, not path
        # segments, so a stdlib list adds the token "go" and silently drops
        # golang.org/x/*, google.golang.org/* and gopkg.in/*.
        GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" save "${PACKAGES[@]}" \
            --save_path="${save_dir}" \
            --force \
            --ignore="${LOCAL_MODULE}"

        GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" csv "${PACKAGES[@]}" \
            --ignore="${LOCAL_MODULE}" \
            >> "${COMBINED_CSV}"

        merge_licenses "${save_dir}" "${LICENSES_DIR}"
    done
}

# Module cache files are 0444 and cp preserves that, so the next platform's copy
# fails unless write permission is restored.
merge_licenses() {
    cp -R "$1/." "$2/"
    chmod -R u+w "$2"
}

# Licenses are joined, not picked: go-licenses emits a row per recognized license,
# so keeping one would hide filepath-securejoin's MPL-2.0 behind its BSD-3-Clause.
collapse_index() {
    LC_ALL=C sort -u "$1" | awk -F, '
        {
            pkg = $1
            if (!(pkg in url)) { url[pkg] = $2; order[++n] = pkg }
            if (!((pkg SUBSEP $3) in seen)) {
                seen[pkg SUBSEP $3] = 1
                # Count, do not test "pkg in lic": mawk instantiates the
                # assignment target before evaluating the right-hand side, so
                # that test is true on the first row and BSD awk disagrees.
                lic[pkg] = (cnt[pkg]++ ? lic[pkg] " / " : "") $3
            }
        }
        END { for (i = 1; i <= n; i++) print order[i] "," url[order[i]] "," lic[order[i]] }
    '
}

# Rows carry the module path and version, not a URL: in vendor mode go-licenses
# points into this repo at HEAD, which stops describing released content once
# main moves and names our copy rather than upstream. The verified upstream
# location comes from hack/license-urls.tsv. Longest-prefix match, because a
# license may sit below the module root.
annotate_modules() {
    awk -v modfile="${1:-${MODULES_TXT}}" '
        BEGIN {
            FS = OFS = ","
            while ((getline line < modfile) > 0) {
                if (line !~ /^# /) continue
                split(line, f, " ")
                # "# <path> <version>", optionally "=> <path> <version>". The
                # replacement is what is vendored; a filesystem replace has no
                # version, so stop rather than misstate it.
                if (f[4] == "=>" || f[3] == "=>") {
                    r = (f[4] == "=>") ? 5 : 4
                    if (f[r + 1] == "") {
                        print "ERROR: " modfile " replaces " f[2] " with a local path;" > "/dev/stderr"
                        print "teach hack/generate-third-party-notices.sh how to attribute it." > "/dev/stderr"
                        exit 1
                    }
                    mods[++m] = f[2]
                    disp[f[2]] = f[r]
                    ver[f[2]] = f[r + 1]
                } else {
                    mods[++m] = f[2]
                    disp[f[2]] = f[2]
                    ver[f[2]] = f[3]
                }
            }
            close(modfile)
            # A read error makes getline return -1 and the loop never runs.
            if (m == 0) {
                print "ERROR: no module lines read from " modfile > "/dev/stderr"
                exit 1
            }
        }
        {
            best = ""
            for (i = 1; i <= m; i++) {
                mp = mods[i]
                if (($1 == mp || index($1, mp "/") == 1) && length(mp) > length(best)) best = mp
            }
            print $0, (best == "" ? "unknown" : disp[best]), (best == "" ? "unknown" : ver[best])
        }
    '
}

# Their vendor tree is the submodule's, not this repository's, so a version can
# differ from the one vendored here.
collect_bundled() {
    local platform goos goarch save_dir local_module

    [[ -f "${LNC_MODULES_TXT}" ]] \
        || die "${LNC_MODULES_TXT} not found." \
               "Run 'git submodule update --init ${LNC_DIR}' — the image ships this" \
               "submodule's libraries, so its dependencies must be listed."

    local_module="$(cd "${LNC_GO_DIR}" && go list -m 2>/dev/null || true)"
    [[ -n "${local_module}" ]] \
        || die "could not determine the module path of ${LNC_GO_DIR} via 'go list -m'."

    for platform in "${PLATFORMS[@]}"; do
        goos="${platform%/*}"
        goarch="${platform#*/}"
        log "Collecting bundled licenses for ${goos}/${goarch}..."
        save_dir="${SAVE_ROOT}/bundled/${goos}_${goarch}"
        (
            cd "${LNC_GO_DIR}"
            export GOFLAGS="-mod=vendor"
            GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" csv "${LNC_PACKAGES[@]}" \
                --ignore="${local_module}"
        ) >> "${BUNDLED_CSV}"
    done

    [[ -s "${BUNDLED_CSV}" ]] \
        || die "go-licenses produced no entries for the bundled libraries under ${LNC_GO_DIR}."
}

# One index for the whole image. The two trees are a build-time detail: what
# ships is one filesystem, so a module both trees pull at different versions is
# two honest rows rather than a second table the reader has to reconcile. The
# source tree moves into the row as a sixth field, since it is now per row
# rather than per table. Same package at the same version is one row; the bytes
# are identical, so this repository's own copy wins.
merge_indexes() {
    cat <(sed 's/$/,vendor/' "$1") <(sed 's/$/,bundled/' "$2") \
        | LC_ALL=C awk -F, '!seen[$1 FS $5]++' \
        | LC_ALL=C sort -t, -k1,1 -k5,5
}

module_source_dir() {
    local module="$1" source_kind="$2"
    case "${source_kind}" in
        vendor)  printf '%s' "${VENDOR_DIR}/${module}" ;;
        bundled) printf '%s' "${LNC_VENDOR_DIR}/${module}" ;;
        *) die "unknown module source kind '${source_kind}' for ${module}." ;;
    esac
}

build_indexes() {
    log "Generating dependency index..."
    collapse_index "${COMBINED_CSV}" | annotate_modules > "${INDEX_FILE}"
    collapse_index "${BUNDLED_CSV}" | annotate_modules "${LNC_MODULES_TXT}" > "${BUNDLED_INDEX}"

    [[ -s "${INDEX_FILE}" ]] \
        || die "go-licenses produced no entries for ${PACKAGES[*]} — refusing to write empty notices file."
    [[ -s "${BUNDLED_INDEX}" ]] \
        || die "go-licenses produced no entries for the bundled libraries — refusing to write incomplete notices."

    if cut -d, -f4 "${BUNDLED_INDEX}" | LC_ALL=C grep -qx 'unknown'; then
        die "some bundled packages could not be matched to a module in ${LNC_MODULES_TXT}."
    fi

    if cut -d, -f5 "${BUNDLED_INDEX}" | LC_ALL=C grep -qx 'unknown'; then
        die "some bundled packages could not be matched to a version in ${LNC_MODULES_TXT}."
    fi

    if cut -d, -f4 "${INDEX_FILE}" | LC_ALL=C grep -qx 'unknown'; then
        die "some runtime packages could not be matched to a module in ${MODULES_TXT}." \
            "Re-run 'make vendor' first; if it persists, fix annotate_modules in hack/generate-third-party-notices.sh."
    fi

    if cut -d, -f5 "${INDEX_FILE}" | LC_ALL=C grep -qx 'unknown'; then
        die "some runtime packages could not be matched to a version in ${MODULES_TXT}." \
            "Re-run 'make vendor' first; if it persists, fix annotate_modules in hack/generate-third-party-notices.sh."
    fi

    # An unclassifiable license is reported as "Unknown" with a zero exit, so
    # without this an entry that attributes nothing would ship.
    if cut -d, -f3 "${INDEX_FILE}" | LC_ALL=C grep -qE '(^| / )Unknown( / |$)'; then
        die "go-licenses could not identify a license for some dependencies." \
            "Check the entries reported as Unknown before committing the file."
    fi

    merge_indexes "${INDEX_FILE}" "${BUNDLED_INDEX}" > "${MERGED_INDEX}"

    check_override_coverage "${MERGED_INDEX}"
}

# A dropped dependency would otherwise leave its row in LICENSE_OVERRIDES
# silently asserting a license for a package no longer shipped.
check_override_coverage() {
    local index="$1" override_package
    while IFS=$'\t' read -r override_package _ _; do
        case "${override_package}" in
            ''|'#'*) continue ;;
        esac
        LC_ALL=C cut -d, -f1 "${index}" | LC_ALL=C grep -qFx "${override_package}" \
            || die "${LICENSE_OVERRIDES} has a row for ${override_package}, which is not in the generated index." \
                   "Remove that row from ${LICENSE_OVERRIDES} — the dependency was likely dropped."
    done < "${LICENSE_OVERRIDES}"
}

# For restricted licenses 'go-licenses save' copies the whole module source, so
# a name filter is the only thing keeping non-license files out.
license_files_for() {
    local search_dir="$1" license_file file_basename
    [[ -d "${search_dir}" ]] || return 0
    while IFS= read -r -d '' license_file; do
        file_basename="$(basename "${license_file}")"
        # Exclude source files: the name pattern below also matches source files
        # that merely open with a license-shaped header, e.g. a Go file named
        # license.go beginning "// Copyright ...".
        case "${file_basename}" in
            *.go|*.c|*.h|*.s|*.py|*.sh|*.java|*.ts|*.js) continue ;;
        esac
        if printf '%s' "${file_basename}" \
            | LC_ALL=C grep -qiE '^(licen[cs]e|notice|copying|copyright|authors|patents)([-._].*)?$'; then
            printf '%s\n' "${license_file}"
        fi
    done < <(find "${search_dir}" -maxdepth 1 -type f -print0 2>/dev/null | LC_ALL=C sort -z)
}

LICENSE_URLS="${LICENSE_URLS:-hack/license-urls.tsv}"
LICENSE_OVERRIDES="${LICENSE_OVERRIDES:-hack/license-overrides.tsv}"
VENDOR_DIR="${VENDOR_DIR:-vendor}"

# Separate from check_prerequisites: hack/verify-license-urls.sh reuses the
# collection stages to discover which license files the document will link, and
# it is the command that produces this map, so it must run without it.
require_url_map() {
    [[ -f "${LICENSE_URLS}" ]] \
        || die "${LICENSE_URLS} not found." \
               "Run 'make third-party-notices-urls' (needs network) and commit the result."
}

# A single license file can bundle more than one license, which go-licenses
# reports as whichever one it scores highest; LICENSE_OVERRIDES corrects the
# identifier by hand without touching the license text, which is unaffected.
license_identifier_for() {
    local package="$1" default_identifier="$2" override_identifier
    override_identifier="$(LC_ALL=C awk -F'\t' -v pkg="${package}" \
        '$1 == pkg { print $2; exit }' "${LICENSE_OVERRIDES}")"
    printf '%s' "${override_identifier:-${default_identifier}}"
}

# Nearest enclosing directory wins, matching how go-licenses attributes a
# license to the packages beneath it.
license_dir_within_module() {
    local module="$2" dir="$1" module_dir="$3" relative_license_dir
    while :; do
        if [[ -n "$(license_files_for "${module_dir}${dir#"${module}"}")" ]]; then
            relative_license_dir="${dir#"${module}"}"
            printf '%s' "${relative_license_dir#/}"
            return 0
        fi
        [[ "${dir}" == "${module}" ]] && return 1
        [[ "${dir}" != */* ]] && return 1
        dir="${dir%/*}"
    done
}

location_for() {
    local url
    url="$(LC_ALL=C awk -F'\t' -v m="$1" -v v="$2" -v p="$3" \
        '$1 == m && $2 == v && $3 == p { print $4; found = 1; exit }
         END { exit !found }' "${LICENSE_URLS}")" || return 1
    [[ -n "${url}" ]] || return 1
    printf '%s' "${url}"
}

# Joined with ' / ' so the cell lines up with how the License column joins
# identifiers for a module that ships more than one license file.
license_location_links() {
    local package="$1" module="$2" version="$3" module_dir="$4"
    local relative_license_dir license_file_name license_path url cell="" license_file governing_dir
    relative_license_dir="$(license_dir_within_module "${package}" "${module}" "${module_dir}")" \
        || die "no license file found for ${package} under ${module_dir}." \
               "Run 'make vendor' and re-run."
    governing_dir="${module_dir}${relative_license_dir:+/${relative_license_dir}}"
    while IFS= read -r license_file; do
        [[ -z "${license_file}" ]] && continue
        license_file_name="$(basename "${license_file}")"
        license_path="${relative_license_dir:+${relative_license_dir}/}${license_file_name}"
        url="$(location_for "${module}" "${version}" "${license_path}")" \
            || die "${LICENSE_URLS} has no verified URL for ${module}@${version} ${license_path}." \
                   "Run 'make third-party-notices-urls' (needs network) and commit the result."
        cell="${cell:+${cell} / }[${license_file_name}](${url})"
    done < <(license_files_for "${governing_dir}")
    [[ -n "${cell}" ]] || die "no license file for ${package} under ${governing_dir}." \
                              "Run 'make vendor' and re-run."
    printf '%s' "${cell}"
}

emit_index_table() {
    local index="$1" package _url license module version source_kind location license_identifier module_dir
    printf '| Package | Version | License | Location |\n'
    printf '|---------|---------|---------|----------|\n'

    while IFS=, read -r package _url license module version source_kind; do
        [[ -z "${package}" ]] && continue
        module_dir="$(module_source_dir "${module}" "${source_kind}")"
        location="$(license_location_links "${package}" "${module}" "${version}" "${module_dir}")"
        license_identifier="$(license_identifier_for "${package}" "${license:-Unknown}")"
        # shellcheck disable=SC2016  # backticks are literal markdown here.
        printf '| `%s` | %s | %s | %s |\n' \
            "${package}" "${version:-unknown}" \
            "${license_identifier}" "${location}"
    done < "${index}"
}

emit_sections() {
    local index="$1"
    local package _url license module version source_kind files license_file fence relative_license_dir license_file_name url governing_dir license_identifier module_dir

    while IFS=, read -r package _url license module version source_kind; do
        [[ -z "${package}" ]] && continue

        license_identifier="$(license_identifier_for "${package}" "${license:-Unknown}")"
        printf '### %s\n\n' "${package}"
        printf '* Version: %s\n' "${version:-unknown}"
        printf '* License: %s\n\n' "${license_identifier}"

        module_dir="$(module_source_dir "${module}" "${source_kind}")"
        relative_license_dir="$(license_dir_within_module "${package}" "${module}" "${module_dir}")" \
            || die "no license file found for ${package} under ${module_dir}." \
                   "Run 'make vendor' and re-run."
        governing_dir="${module_dir}${relative_license_dir:+/${relative_license_dir}}"

        files=()
        while IFS= read -r license_file; do
            [[ -n "${license_file}" ]] && files+=("${license_file}")
        done < <(license_files_for "${governing_dir}")

        if (( ${#files[@]} == 0 )); then
            printf 'License text unavailable. See upstream source for the full license.\n'
        else
            for license_file in "${files[@]}"; do
                license_file_name="$(basename "${license_file}")"
                url="$(location_for "${module}" "${version}" "${relative_license_dir:+${relative_license_dir}/}${license_file_name}")" \
                    || die "${LICENSE_URLS} has no verified URL for ${module}@${version} ${relative_license_dir:+${relative_license_dir}/}${license_file_name}." \
                           "Run 'make third-party-notices-urls' (needs network) and commit the result."
                fence="$(fence_for "${license_file}")"
                printf '#### %s\n\n' "${license_file_name}"
                printf '<%s>\n\n' "${url}"
                printf '%stext\n' "${fence}"
                cat "${license_file}"
                echo
                printf '%s\n' "${fence}"
                echo
            done
        fi
        echo
    done < "${index}"
}

# libnvidia-container statically links these into the shared libraries the
# image ships, so their terms are redistributed here. elftoolchain and
# nvidia-modprobe carry no license file of their own; their terms live in the
# per-file copyright blocks scraped below.

sha256_of_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

read_make_var() {
    local file="$1" name="$2" make_value
    make_value=$(LC_ALL=C sed -n "s/^${name}[[:space:]]*:=[[:space:]]*//p" "${file}" | head -1)
    make_value="${make_value%"${make_value##*[![:space:]]}"}"
    [[ -n "${make_value}" ]] || die "could not read ${name} from ${file}."
    printf '%s' "${make_value}"
}

expand_make_vars() {
    local expanded="$1" version="$2" prefix="${3:-}"
    # libtirpc tags releases with the version's dots turned into dashes.
    expanded="${expanded//\$(VERSION_DASHED)/${version//./-}}"
    expanded="${expanded//\$(VERSION)/${version}}"
    expanded="${expanded//\$(PREFIX)/${prefix}}"
    # shellcheck disable=SC2016  # matching a literal '$(' left over by make.
    case "${expanded}" in
        *'$('*) die "unexpanded make variable in '${expanded}'." ;;
    esac
    printf '%s' "${expanded}"
}

extract_notice_blocks() {
    LC_ALL=C awk -v separator="${BLOCK_SEP}" '
        !in_block && /\/\*/ { in_block = 1; block = "" }
        in_block {
            line = $0
            sub(/[ \t]*\*\/[ \t]*$/, "", line)
            sub(/^[ \t]*\/\*[-*!]?[ \t]?/, "", line)
            sub(/^[ \t]*\*[ \t]?/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line != "" || $0 !~ /\*\//) block = block line "\n"
            if ($0 ~ /\*\//) {
                if (block ~ /Copyright/) printf "%s%s\n", block, separator
                in_block = 0
            }
        }
    ' "$1"
}

dedupe_notice_blocks() {
    LC_ALL=C awk -v separator="${BLOCK_SEP}" '
        $0 == separator {
            gsub(/^\n+/, "", block)
            gsub(/\n+$/, "\n", block)
            if (block != "" && !(block in seen)) {
                seen[block] = 1
                if (emitted_blocks++) print "----------------------------------------------------------------------"
                printf "%s", block
            }
            block = ""
            next
        }
        { block = block $0 "\n" }
        END { printf "%d\n", emitted_blocks > "/dev/stderr" }
    '
}

fetch_license_bytes() {
    local url="$1" destination="$2" label="$3"
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --output "${destination}.encoded" "${url}" \
        || die "could not fetch the license location for ${label}:" \
               "  ${url}" \
               "This script needs network access; it will not write an unverified link."
    case "${url}" in
        *'?format=TEXT')
            # GNU coreutils spells the decode flag -d, BSD spells it -D.
            if base64 -d < "${destination}.encoded" > "${destination}" 2>/dev/null; then
                :
            elif base64 -D < "${destination}.encoded" > "${destination}" 2>/dev/null; then
                :
            else
                die "could not base64-decode the license location for ${label}:" "  ${url}"
            fi
            ;;
        *)
            mv -f "${destination}.encoded" "${destination}"
            ;;
    esac
}

verify_remote_matches() {
    local url="$1" local_file="$2" label="$3" remote_file="$4"
    local local_sha remote_sha
    fetch_license_bytes "${url}" "${remote_file}" "${label}"
    local_sha="$(sha256_of_file "${local_file}")"
    remote_sha="$(sha256_of_file "${remote_file}")"
    [[ "${local_sha}" == "${remote_sha}" ]] \
        || die "the license location for ${label} does not serve the bytes reproduced here." \
               "  url:             ${url}" \
               "  upstream sha256: ${remote_sha}" \
               "  local    sha256: ${local_sha}" \
               "Upstream may have retagged, or the URL points at a different revision."
}

resolve_license_location() {
    local dependency_id="$1" location_path="$2" location_url="$3"
    local archive_file remote_file

    if [[ "${location_path}" == "none" ]]; then
        [[ -n "${location_url}" ]] \
            || die "${dependency_id} declares no license file but gives no reason."
        printf '%s' "${location_url}"
        return 0
    fi

    archive_file="${C_ROOT}/${location_path}"
    [[ -f "${archive_file}" ]] \
        || die "${dependency_id} ${C_VERSION} does not contain ${location_path}, which C_DEPS pins as its license file."

    remote_file="${WORK_DIR}/c/${dependency_id}.location"
    verify_remote_matches "${location_url}" "${archive_file}" \
        "${dependency_id} ${C_VERSION} ${location_path}" "${remote_file}"

    printf '[%s](%s)' "${location_path}" "${location_url}"
}

fetch_c_dependency() {
    local dependency_id="$1" makefile="$2" tar_members="$3"
    local version prefix url decompress_flag unpack_dir tarball archive_root decompressor

    [[ -f "${makefile}" ]] \
        || die "${makefile} not found." \
               "Run 'git submodule update --init ${LNC_DIR}'."

    version="$(read_make_var "${makefile}" VERSION)"
    prefix="$(expand_make_vars "$(read_make_var "${makefile}" PREFIX)" "${version}")"
    url="$(expand_make_vars "$(read_make_var "${makefile}" URL)" "${version}" "${prefix}")"

    case "${url}" in
        *.tar.bz2) decompress_flag="-j"; decompressor="bzip2" ;;
        *.tar.gz|*.tgz) decompress_flag="-z"; decompressor="gzip" ;;
        *) die "unsupported archive type for ${dependency_id}: ${url}" ;;
    esac
    command -v "${decompressor}" >/dev/null 2>&1 \
        || die "${decompressor} is required to unpack ${dependency_id}, but is not installed."

    unpack_dir="${WORK_DIR}/c/${dependency_id}"
    tarball="${WORK_DIR}/${dependency_id}.tar"
    mkdir -p "${unpack_dir}"

    log "Fetching ${dependency_id} ${version} from ${url}..."
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --output "${tarball}" "${url}" \
        || die "failed to download ${dependency_id} ${version} from ${url}." \
               "This script needs network access; it will not emit a placeholder license."

    local -a member_args=()
    local member
    # shellcheck disable=SC2086  # the member list is a deliberate word split.
    for member in ${tar_members}; do
        member_args+=("${prefix}/${member}")
    done
    tar -C "${unpack_dir}" -x "${decompress_flag}" -f "${tarball}" \
        ${member_args[@]+"${member_args[@]}"} \
        || die "failed to unpack ${dependency_id} ${version} from ${url}."
    rm -f "${tarball}"

    archive_root="${unpack_dir}/${prefix}"
    [[ -d "${archive_root}" ]] \
        || die "${dependency_id} ${version} did not unpack into '${prefix}/' as ${makefile} expects."

    C_VERSION="${version}"
    C_URL="${url}"
    C_ROOT="${archive_root}"
}

collect_c_notices() {
    local dependency_record dependency_id makefile tar_members license_files
    local notice_paths build_condition declared_license location_path location_url
    local notices_file blocks_file path source_file scanned_file_count distinct_notice_count
    local location_cell_value

    for dependency_record in "${C_DEPS[@]}"; do
        IFS='|' read -r dependency_id makefile tar_members license_files \
            notice_paths build_condition declared_license location_path location_url \
            <<< "${dependency_record}"

        [[ -n "${location_path}" ]] \
            || die "${dependency_id} has no license-location field in C_DEPS."

        fetch_c_dependency "${dependency_id}" "${makefile}" "${tar_members}"

        notices_file="${WORK_DIR}/c/${dependency_id}.notices"
        blocks_file="${WORK_DIR}/c/${dependency_id}.blocks"
        : > "${notices_file}"
        : > "${blocks_file}"

        # shellcheck disable=SC2086  # the path lists are deliberate word splits.
        for path in ${license_files}; do
            [[ -f "${C_ROOT}/${path}" ]] \
                || die "${dependency_id} ${C_VERSION} does not contain ${path}, which ${makefile} pins as its license file."
            printf '%s\n' "--- ${path} ---" >> "${notices_file}"
            cat "${C_ROOT}/${path}" >> "${notices_file}"
        done

        scanned_file_count=0
        # shellcheck disable=SC2086
        for path in ${notice_paths}; do
            [[ -e "${C_ROOT}/${path}" ]] \
                || die "${dependency_id} ${C_VERSION} does not contain ${path}; update C_DEPS."
            while IFS= read -r source_file; do
                extract_notice_blocks "${source_file}" >> "${blocks_file}"
                scanned_file_count=$(( scanned_file_count + 1 ))
            done < <(find "${C_ROOT}/${path}" -type f | LC_ALL=C grep -E "${NOTICE_SOURCE_RE}" | LC_ALL=C sort)
        done
        (( scanned_file_count > 0 )) \
            || die "found no source files to scan for ${dependency_id} under: ${notice_paths}"

        dedupe_notice_blocks < "${blocks_file}" >> "${notices_file}" \
            2>"${WORK_DIR}/c/${dependency_id}.count"
        distinct_notice_count=$(tr -d '[:space:]' < "${WORK_DIR}/c/${dependency_id}.count")
        (( distinct_notice_count > 0 )) \
            || die "extracted no copyright notices from ${scanned_file_count} ${dependency_id} source files." \
                   "The comment format probably changed; fix extract_notice_blocks."

        [[ -s "${notices_file}" ]] \
            || die "no license text collected for ${dependency_id} ${C_VERSION}."

        location_cell_value="$(resolve_license_location "${dependency_id}" "${location_path}" \
            "$(expand_make_vars "${location_url}" "${C_VERSION}")")"

        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "${dependency_id}" "${C_VERSION}" "${build_condition}" "${declared_license}" \
            "${C_URL}" "${makefile}" "${scanned_file_count}" "${distinct_notice_count}" \
            "${location_cell_value}" >> "${C_INDEX}"
        log "  ${dependency_id} ${C_VERSION}: ${distinct_notice_count} distinct notices from ${scanned_file_count} files"
    done

    [[ -s "${C_INDEX}" ]] || die "no bundled C dependencies were collected."

    if cut -d'|' -f4 "${C_INDEX}" | LC_ALL=C grep -qE '^$|(^| )Unknown( |$)'; then
        die "a bundled C dependency has no declared license identifier."
    fi
}

emit_fenced_file() {
    local file="$1" fence
    fence="$(fence_for "${file}")"
    printf '%stext\n' "${fence}"
    cat "${file}"
    echo
    printf '%s\n' "${fence}"
    echo
}

emit_c_table() {
    local dependency_id version build_condition declared_license url makefile
    local scanned_file_count distinct_notice_count location
    printf '| Dependency | Version | Built when | License (declared) | Pinned in | Location |\n'
    printf '|------------|---------|------------|--------------------|-----------|----------|\n'
    while IFS='|' read -r dependency_id version build_condition declared_license url makefile \
        scanned_file_count distinct_notice_count location; do
        [[ -z "${dependency_id}" ]] && continue
        # shellcheck disable=SC2016  # backticks are literal markdown here.
        printf '| `%s` | %s | `%s` | %s | `%s` | %s |\n' \
            "${dependency_id}" "${version}" "${build_condition}" "${declared_license}" \
            "${makefile}" "${location}"
    done < "${C_INDEX}"
}

emit_c_sections() {
    local dependency_id version build_condition declared_license url makefile
    local scanned_file_count distinct_notice_count location
    while IFS='|' read -r dependency_id version build_condition declared_license url makefile \
        scanned_file_count distinct_notice_count location; do
        [[ -z "${dependency_id}" ]] && continue
        printf '### %s\n\n' "${dependency_id}"
        printf '* Version: %s\n' "${version}"
        printf '* Declared license: %s\n' "${declared_license}"
        # shellcheck disable=SC2016  # backticks are literal markdown here.
        printf '* Built when: `%s`\n' "${build_condition}"
        # shellcheck disable=SC2016
        printf '* Pinned in: `%s`\n' "${makefile}"
        printf '* Source: %s\n' "${url}"
        printf '* Notices: %s distinct, gathered from %s compiled or installed source files\n\n' \
            "${distinct_notice_count}" "${scanned_file_count}"
        emit_fenced_file "${WORK_DIR}/c/${dependency_id}.notices"
    done < "${C_INDEX}"
}

compose_document() {
    require_url_map
    log "Composing ${OUTPUT}..."
    {
        cat <<'EOF'
# Third-Party Notices

NVIDIA Container Toolkit

This file lists every third-party dependency that NVIDIA Container Toolkit
redistributes, along with the verbatim text of each dependency's license. In
particular, this covers all **Go modules** statically linked into the commands
under `cmd/`. The `nvidia-container-runtime-hook`, `nvidia-container-runtime`,
`nvidia-container-runtime.cdi`, `nvidia-container-runtime.legacy`, `nvidia-ctk`
and `nvidia-cdi-hook` commands ship in the deb and rpm packages. The
`nvidia-ctk-installer` command ships in the `container-toolkit` image.

The image also ships the extracted deb and rpm payloads under `/artifacts`,
which carry libnvidia-container's `libnvidia-container.so`,
`libnvidia-container.a`, `libnvidia-container-go.so` and `nvidia-container-cli`
built from the `third_party/libnvidia-container` submodule. Its Go modules are
listed alongside this repository's own below, and the C libraries statically
linked into those objects are listed under Bundled C Dependencies. Where the
submodule and this repository link the same module at different versions, both
copies ship and both are listed.

Go standard library packages are excluded; they are covered by the license of
the Go distribution itself. Modules that no shipped command or library links
are not listed; those are vendored only for tests and build tooling.

Each dependency is listed with the version redistributed, and its Location
links to the license file in that version's upstream repository.

The `container-toolkit` image uses `nvcr.io/nvidia/distroless/go` as a base image.
All of the OSS packages and source included in this image can be found at
https://developer.nvidia.com/w/distroless-oss/index.html. A statically compiled
busybox binary is added to the image, which is licensed under GPLv2.

## Go Module Index

EOF
        emit_index_table "${MERGED_INDEX}"

        cat <<'EOF'

## Bundled C Dependency Index

`Location` is the dependency's own license file upstream, pinned to the version
built here and checked by fetching it and comparing it byte for byte with the
copy inside the archive. Where a dependency has no license file to link, the
column says why; its terms are the per-file copyright notices reproduced below.

EOF
        emit_c_table

        cat <<'EOF'

## Go Module License Texts

EOF
        emit_sections "${MERGED_INDEX}"

        cat <<'EOF'
## Bundled C Dependency License Texts

EOF
        emit_c_sections
    } > "${OUT_TMP}"

    # mv, not cp: OUT_TMP is in OUTPUT's directory, so this is a rename(2) and
    # OUTPUT is never a partial write. mktemp creates 0600, hence the chmod.
    chmod 644 "${OUT_TMP}"
    mv "${OUT_TMP}" "${OUTPUT}"
}

main() {
    check_prerequisites
    verify_platform_matrix
    prepare_workspace

    collect_runtime
    collect_bundled
    build_indexes
    collect_c_notices
    compose_document

    local go_count c_count
    go_count=$(wc -l < "${MERGED_INDEX}" | tr -d ' ')
    c_count=$(wc -l < "${C_INDEX}" | tr -d ' ')
    log "Wrote ${OUTPUT} (${go_count} Go packages, ${c_count} bundled C dependencies)"
}

# Sourced by the tests and by hack/verify-license-urls.sh, which reuse these
# functions without the side effects of a full run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
