#!/usr/bin/env bash
#
#  resign_adhoc.sh
#  Air2
#
#  Copyright (C) 2026 Air-Devs and contributors.
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0.txt>.
#
#  SPDX-License-Identifier: GPL-3.0-or-later
# Re-signs a Mach-O ad-hoc using codesign, preserving any entitlements already
# embedded in the binary (or applying the file given as the 2nd argument).
#
# The repo previously used `ldid -S` here, but the Homebrew ldid build produces
# CodeDirectories without the CS_ADHOC flag (flags=0x0), which Apple's tooling
# reports as "not signed at all" and strict dlopen paths on device reject.
# codesign -f -s - sets the proper adhoc flag.
set -euo pipefail

FILE="${1:?usage: resign_adhoc.sh <file> [entitlements.xml]}"
ENTS_FILE="${2:-}"

tmp_ents=""
cleanup() { [ -n "$tmp_ents" ] && rm -f "$tmp_ents" || true; }
trap cleanup EXIT

if [ -z "$ENTS_FILE" ]; then
    # Preserve entitlements already embedded in the existing signature, if any.
    tmp_ents="$(mktemp -t amethyst-ents.XXXXXX)"
    if codesign -d --entitlements :"$tmp_ents" "$FILE" >/dev/null 2>&1 && [ -s "$tmp_ents" ]; then
        ENTS_FILE="$tmp_ents"
    else
        rm -f "$tmp_ents"
        tmp_ents=""
    fi
fi

codesign --force --sign - ${ENTS_FILE:+--entitlements "$ENTS_FILE"} "$FILE"
