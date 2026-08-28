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

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/test-helpers.sh disable=SC1091
source "${HERE}/test-helpers.sh"

# If the guard ever regresses, sourcing must not overwrite the committed
# notices file. OUTPUT is honoured by compose_document.
OUTPUT="$(mktemp)"
export OUTPUT

# shellcheck source=hack/generate-third-party-notices.sh disable=SC1091
source "${HERE}/generate-third-party-notices.sh"

# If the guard is missing, sourcing runs the generator and exits before here.
assert_eq "sourced" "sourced" "sourcing the generator does not execute main"

# Environment-independent: proves the guard is present rather than relying on
# main failing fast, which it only does on a host without go-licenses.
assert_eq "1" \
    "$(LC_ALL=C grep -c 'BASH_SOURCE\[0\]' "${HERE}/generate-third-party-notices.sh")" \
    "the generator guards main against running on source"

fixture="$(mktemp)"
trap 'rm -f "${fixture}"' EXIT
printf 'plain text, no backticks\n' > "${fixture}"
assert_eq '```' "$(fence_for "${fixture}")" "fence_for: minimum width is three"
printf 'a ```` b\n' > "${fixture}"
assert_eq '`````' "$(fence_for "${fixture}")" "fence_for: one wider than the longest run"

modules_fixture="$(mktemp)"
cat > "${modules_fixture}" <<'MODULES'
# sigs.k8s.io/yaml v1.4.0
## explicit
# gopkg.in/yaml.v3 v3.0.1
MODULES

index_input="$(mktemp)"
cat > "${index_input}" <<'ROWS'
sigs.k8s.io/yaml,ignored,Apache-2.0
sigs.k8s.io/yaml/goyaml.v2,ignored,Apache-2.0
gopkg.in/yaml.v3,ignored,MIT
ROWS

assert_eq "sigs.k8s.io/yaml/goyaml.v2,ignored,Apache-2.0,sigs.k8s.io/yaml,v1.4.0" \
    "$(MODULES_TXT="${modules_fixture}" annotate_modules < "${index_input}" | sed -n 2p)" \
    "annotate_modules appends module and version"
assert_eq "gopkg.in/yaml.v3,ignored,MIT,gopkg.in/yaml.v3,v3.0.1" \
    "$(MODULES_TXT="${modules_fixture}" annotate_modules < "${index_input}" | sed -n 3p)" \
    "annotate_modules resolves a root module"

urls_fixture="$(mktemp)"
{
    printf 'sigs.k8s.io/yaml\tv1.4.0\tLICENSE\thttps://example.invalid/yaml\n'
    printf 'sigs.k8s.io/yaml\tv1.4.0\tgoyaml.v2/LICENSE\thttps://example.invalid/goyaml-license\n'
    printf 'sigs.k8s.io/yaml\tv1.4.0\tgoyaml.v2/LICENSE.libyaml\thttps://example.invalid/goyaml-libyaml\n'
    printf 'gopkg.in/yaml.v3\tv3.0.1\tLICENSE\thttps://example.invalid/yaml-v3\n'
} > "${urls_fixture}"

# No rows: exercises license_identifier_for's not-found path so the fixtures
# below that do not care about overrides are unaffected by them, without
# depending on the LICENSE_OVERRIDES default resolving from the test's cwd.
empty_overrides_fixture="$(mktemp)"
printf '# no overrides\n' > "${empty_overrides_fixture}"

assert_eq "https://example.invalid/goyaml-license" \
    "$(LICENSE_URLS="${urls_fixture}" location_for \
        sigs.k8s.io/yaml v1.4.0 goyaml.v2/LICENSE)" \
    "location_for finds a nested license path"
# $1 is expanded by the child bash -c, not here.
# shellcheck disable=SC2016
assert_fails "location_for fails closed on a miss" \
    env LICENSE_URLS="${urls_fixture}" bash -c \
    'source "$1"; location_for github.com/nope v1.0.0 LICENSE' \
    _ "${HERE}/generate-third-party-notices.sh"

license_files_fixture="$(mktemp -d)"
touch "${license_files_fixture}/LICENSE" "${license_files_fixture}/LICENSE.md" "${license_files_fixture}/license.go"
assert_eq "$(printf '%s/LICENSE\n%s/LICENSE.md' "${license_files_fixture}" "${license_files_fixture}")" \
    "$(license_files_for "${license_files_fixture}")" \
    "license_files_for excludes a Go source file even when its name matches"
rm -rf "${license_files_fixture}"

vendor_fixture="$(mktemp -d)"
mkdir -p "${vendor_fixture}/sigs.k8s.io/yaml/goyaml.v2"
mkdir -p "${vendor_fixture}/gopkg.in/yaml.v3"
touch "${vendor_fixture}/sigs.k8s.io/yaml/LICENSE"
touch "${vendor_fixture}/sigs.k8s.io/yaml/goyaml.v2/LICENSE"
touch "${vendor_fixture}/sigs.k8s.io/yaml/goyaml.v2/LICENSE.libyaml"
touch "${vendor_fixture}/gopkg.in/yaml.v3/LICENSE"
assert_eq "goyaml.v2" \
    "$(VENDOR_DIR="${vendor_fixture}" license_dir_within_module \
        sigs.k8s.io/yaml/goyaml.v2 sigs.k8s.io/yaml "${vendor_fixture}/sigs.k8s.io/yaml")" \
    "license_dir_within_module finds the nearest enclosing license"
assert_eq "" \
    "$(VENDOR_DIR="${vendor_fixture}" license_dir_within_module \
        sigs.k8s.io/yaml sigs.k8s.io/yaml "${vendor_fixture}/sigs.k8s.io/yaml")" \
    "license_dir_within_module is empty at the module root"
# $1 is expanded by the child bash -c, not here.
# shellcheck disable=SC2016
assert_fails "license_dir_within_module fails when no license exists" \
    env VENDOR_DIR="${vendor_fixture}" bash -c \
    'source "$1"; license_dir_within_module github.com/absent/mod github.com/absent/mod "$2"' \
    _ "${HERE}/generate-third-party-notices.sh" "${vendor_fixture}/github.com/absent/mod"

# merge_indexes: the two trees become one table, and the tree each row was
# hashed against moves into the row.
merge_runtime="$(mktemp)"
merge_bundled="$(mktemp)"
cat > "${merge_runtime}" <<'IDX'
github.com/opencontainers/runtime-spec/specs-go,ignored,Apache-2.0,github.com/opencontainers/runtime-spec,v1.3.0
github.com/google/uuid,ignored,BSD-3-Clause,github.com/google/uuid,v1.6.0
IDX
cat > "${merge_bundled}" <<'IDX'
github.com/opencontainers/runtime-spec/specs-go,ignored,Apache-2.0,github.com/opencontainers/runtime-spec,v1.2.0
github.com/google/uuid,ignored,BSD-3-Clause,github.com/google/uuid,v1.6.0
IDX

assert_eq "3" \
    "$(merge_indexes "${merge_runtime}" "${merge_bundled}" | wc -l | tr -d ' ')" \
    "merge_indexes keeps both versions of a module but collapses an identical pair"

assert_eq "github.com/google/uuid,ignored,BSD-3-Clause,github.com/google/uuid,v1.6.0,vendor
github.com/opencontainers/runtime-spec/specs-go,ignored,Apache-2.0,github.com/opencontainers/runtime-spec,v1.2.0,bundled
github.com/opencontainers/runtime-spec/specs-go,ignored,Apache-2.0,github.com/opencontainers/runtime-spec,v1.3.0,vendor" \
    "$(merge_indexes "${merge_runtime}" "${merge_bundled}")" \
    "merge_indexes tags each row with its tree, sorts, and prefers this repository's copy"

# $1 is expanded by the child bash -c, not here.
# shellcheck disable=SC2016
assert_fails "module_source_dir rejects an unknown source kind" \
    env bash -c 'source "$1"; module_source_dir some/module wat' \
    _ "${HERE}/generate-third-party-notices.sh"

render="$(mktemp -d)"
mkdir -p "${render}/cache/sigs.k8s.io/yaml/goyaml.v2"
printf 'Apache text\n' > "${render}/cache/sigs.k8s.io/yaml/goyaml.v2/LICENSE"
cat > "${render}/index.csv" <<'IDX'
sigs.k8s.io/yaml/goyaml.v2,ignored,Apache-2.0,sigs.k8s.io/yaml,v1.4.0,vendor
gopkg.in/yaml.v3,ignored,MIT,gopkg.in/yaml.v3,v3.0.1,vendor
IDX

assert_eq '| Package | Version | License | Location |' \
    "$(LICENSE_URLS="${urls_fixture}" VENDOR_DIR="${vendor_fixture}" LICENSES_DIR="${render}/cache" \
       LICENSE_OVERRIDES="${empty_overrides_fixture}" emit_index_table "${render}/index.csv" | sed -n 1p)" \
    "index header has four columns"
# Expected literal Markdown, not shell expansion.
# shellcheck disable=SC2016
assert_eq '| `sigs.k8s.io/yaml/goyaml.v2` | v1.4.0 | Apache-2.0 | [LICENSE](https://example.invalid/goyaml-license) / [LICENSE.libyaml](https://example.invalid/goyaml-libyaml) |' \
    "$(LICENSE_URLS="${urls_fixture}" VENDOR_DIR="${vendor_fixture}" LICENSES_DIR="${render}/cache" \
       LICENSE_OVERRIDES="${empty_overrides_fixture}" emit_index_table "${render}/index.csv" | sed -n 3p)" \
    "index row labels the link by filename"

# Regression: a package whose module/version pair has no entry in the URL map
# must abort the whole table, not render with a blank Location cell.
mismatch_index="${render}/mismatch-index.csv"
cat > "${mismatch_index}" <<'IDX'
sigs.k8s.io/yaml/goyaml.v2,ignored,Apache-2.0,sigs.k8s.io/yaml,v9.9.9,vendor
IDX
# $1/$2 are expanded by the child bash -c, not here.
# shellcheck disable=SC2016
assert_fails "emit_index_table fails closed when the URL map has no entry for a row" \
    env LICENSE_URLS="${urls_fixture}" VENDOR_DIR="${vendor_fixture}" LICENSES_DIR="${render}/cache" \
    LICENSE_OVERRIDES="${empty_overrides_fixture}" \
    bash -c 'source "$1"; emit_index_table "$2"' _ "${HERE}/generate-third-party-notices.sh" "${mismatch_index}"

section="$(LICENSE_URLS="${urls_fixture}" VENDOR_DIR="${vendor_fixture}" LICENSES_DIR="${render}/cache" \
    LICENSE_OVERRIDES="${empty_overrides_fixture}" emit_sections "${render}/index.csv")"
assert_eq "* Version: v1.4.0" "$(printf '%s' "${section}" | sed -n 3p)" "section names the version"
assert_eq "* License: Apache-2.0" "$(printf '%s' "${section}" | sed -n 4p)" "section names the license"
assert_eq "0" "$(printf '%s' "${section}" | LC_ALL=C grep -c '^\* Module: ')" "section no longer names the module"
assert_eq "<https://example.invalid/goyaml-license>" \
    "$(printf '%s' "${section}" | LC_ALL=C grep -m1 '^<http')" "section prints the file URL"

overrides_fixture="$(mktemp)"
cat > "${overrides_fixture}" <<'OVERRIDES'
# package	license	reason
sigs.k8s.io/yaml/goyaml.v2	Apache-2.0 / MIT	test fixture
gopkg.in/yaml.v3	Apache-2.0 / MIT	test fixture
OVERRIDES

assert_eq "Apache-2.0 / MIT" \
    "$(LICENSE_OVERRIDES="${overrides_fixture}" license_identifier_for sigs.k8s.io/yaml/goyaml.v2 Apache-2.0)" \
    "license_identifier_for returns the override for a package that has one"
assert_eq "BSD-3-Clause" \
    "$(LICENSE_OVERRIDES="${overrides_fixture}" license_identifier_for sigs.k8s.io/yaml BSD-3-Clause)" \
    "license_identifier_for returns the passed-in default for a package without an override"

# Expected literal Markdown, not shell expansion.
# shellcheck disable=SC2016
assert_eq '| `gopkg.in/yaml.v3` | v3.0.1 | Apache-2.0 / MIT | [LICENSE](https://example.invalid/yaml-v3) |' \
    "$(LICENSE_URLS="${urls_fixture}" VENDOR_DIR="${vendor_fixture}" LICENSES_DIR="${render}/cache" \
       LICENSE_OVERRIDES="${overrides_fixture}" emit_index_table "${render}/index.csv" | sed -n 4p)" \
    "emit_index_table renders the overridden identifier in the License column"

stale_overrides="$(mktemp)"
printf 'github.com/absent/package\tApache-2.0 / MIT\ttest fixture\n' > "${stale_overrides}"
# $1/$2 are expanded by the child bash -c, not here.
# shellcheck disable=SC2016
assert_fails "check_override_coverage fails when an override names a package absent from the index" \
    env LICENSE_OVERRIDES="${stale_overrides}" bash -c \
    'source "$1"; check_override_coverage "$2"' _ "${HERE}/generate-third-party-notices.sh" "${render}/index.csv"

rm -rf "${vendor_fixture}" "${render}"
rm -f "${modules_fixture}" "${index_input}" "${urls_fixture}" "${empty_overrides_fixture}" "${overrides_fixture}" "${stale_overrides}"

finish
