#!/usr/bin/env bash
set -euo pipefail


OUTPUT_RED='\033[1;31m'
OUTPUT_YELLOW='\033[1;33m'
OUTPUT_BLUE='\033[1;34m'
OUTPUT_GREEN='\033[32m'
OUTPUT_RESET="$(tput sgr0)"

error() {
  echo -e "$OUTPUT_RED""$@""$OUTPUT_RESET" >&2
  return 1
}

warning() {
  echo -e "$OUTPUT_YELLOW""$@""$OUTPUT_RESET" >&2
}

title() {
  echo -en "\n$OUTPUT_BLUE#######---$OUTPUT_RESET "
  echo -n "$@"
  echo -en " $OUTPUT_BLUE---#######$OUTPUT_RESET\n"
}

message() {
  echo -e "$OUTPUT_GREEN""$@""$OUTPUT_RESET"
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

assert_additional_packages() {
  # Allow empty
  if [[ -z "${!1:-}" ]]; then
    return 0
  fi

  # Allow array
  if [[ ! "$(declare -p $1)" =~ "declare -a" ]]; then
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

uncomment_line() {
  line="${1:-}"
  file="${2:-}"

  # Checks arguments
  assert_not_empty "$line" "Line is empty"
  test -f "$file" || {
    error "There is no such file: $file"
  }

  # Performs uncommenting
  grep -q "$line" "$file" || {
    error "There is no line \"$line\" in file \"$file\""
  }

  sed -i "s~#\s*$line~$line~g" "$file"
}

