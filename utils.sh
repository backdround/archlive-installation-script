#!/usr/bin/env bash
set -euo pipefail


OUTPUT_RED='\033[1;31m'
OUTPUT_YELLOW='\033[1;33m'
OUTPUT_RESET="$(tput sgr0)"

error() {
  echo -e "$OUTPUT_RED""$@""$OUTPUT_RESET" >&2
  return 1
}

warning() {
  echo -e "$OUTPUT_YELLOW""$@""$OUTPUT_RESET" >&2
}

remove_empty_lines_and_empty_space() {
  echo "$1" | sed 's/ //g; /^$/d'
}

get_partition_path_by_number() {
  local device="$1"
  local nth="$2"
  lsblk -lp "$device" -o NAME | sed -n "$((nth + 2))p"
}


assert_not_empty() {
  test -n "$1" || {
    shift
    error "$@"
  }
}

check_not_empty() {
  test -n "$1" || {
    shift
    warning "$@"
  }
}

assert_internet() {
  ping google.com -c 2 >/dev/null || {
    error "$@"
  }
}

assert_efi() {
  test -d /sys/firmware/efi/efivars || {
    error "$@"
  }
}

assert_live_image() {
  local current_fstype="$(findmnt -T ./ --noheadings --output FSTYPE)"
  test "$current_fstype" == "overlay" || {
    error "$@"
  }
}

assert_block_device() {
  [ -b "$1" ] || {
    shift
    error "$@"
  }
}

assert_size() {
  if [[ ! $1 =~ ^[0-9]+(K|KiB|M|MiB|G|GiB|T|TiB|P|PiB)$ ]]; then
    shift
    error "$@"
  fi
}

check_timezone() {
  test -f "/usr/share/zoneinfo/$1" || {
    shift
    error "$@"
  }
}

check_locales() {
  local locales="$(remove_empty_lines_and_empty_space "$1")"
  local warning_message="$2"

  while read locale; do
    grep "$locale" /etc/locale.gen >/dev/null || {
      warning "$warning_message: $locale"
    }
  done <<< "$locales"
}

check_mirrors() {
  local mirrors="$(remove_empty_lines_and_empty_space "$1")"
  local warning_message="$2"

  while read mirror; do
    if [[ ! $mirror =~ ^(http|https|rsync):// ]]; then
      warning "$warning_message: $mirror"
    fi
  done <<< "$mirrors"
}
