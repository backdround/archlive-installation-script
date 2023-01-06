#!/usr/bin/env bash
set -euo pipefail


source "$(dirname $0)/utils.sh"
source "$(dirname $0)/config"

inspect_initial_assertions() {
  title "Asserting initial checks"

  message "Checking internet"
  assert_internet "Internet isn't available"

  message "Checking EFI"
  assert_efi "EFI not found"

  message "Checking current environment"
  assert_live_image "Launching environment must be a live image"

  message "Checking set variables"

  assert_block_device "$device" "Flash device must be a block device"

  assert_not_empty "$hostname" "hostname name must be set"
  assert_size "$swap_size" "swap_size has incorrect format"
  assert_additional_packages "additional_packages" \
    "additional packages (variable) must be an array if set"
  check_not_empty "$kernel_options" "Kernel options are empty. Are you sure?"

  check_timezone "$timezone" "Unable to find given timezone in current environment"
  check_locales "$locales" "Unable to find given locale in current environment"
  check_mirrors "$mirrors" "Unable to parse format of mirror"
}

setup_mirrors() {
  # Adds user mirrors
  title "Setting up mirrors"
  message "Adding user mirrors"
  echo "$mirrors" | sed "s/^/Server = /g" >> /etc/pacman.d/mirrorlist

  if which curl >/dev/null 2>&1 ; then
    # Adds USA mirrors
    message "Adding USA mirrors"
    request="https://archlinux.org/mirrorlist/?country=US&protocol=https&use_mirror_status=on"
    curl -s "$request" | sed -e 's/^#Server/Server/' -e '/^#/d' -e '/^$/d' >> /etc/pacman.d/mirrorlist
  fi

  # Updates database after mirrors change
  message "Updating database with new mirrrors"
  pacman --noconfirm -Syy
}

part_device() {
  title "Parting device"

  # Parts device
  wipefs --all "$device" && sync "$device"
  message "Parting $device"
  echo "\
  label: gpt
  start=2048, size=240M, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  size=$swap_size, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
  type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$rootfs_uuid
  write
  " | sfdisk --wipe-partitions always --quiet "$device" | cat
  sync "$device" && sleep 0.3

  efi_partition="$(get_partition_path_by_number "$device" 1)"
  swap_partition="$(get_partition_path_by_number "$device" 2)"
  root_partition="$(get_partition_path_by_number "$device" 3)"

  # Makes filesystems
  message "Makeing filesystems on $device"
  wipefs --all "$efi_partition" "$swap_partition" "$root_partition" && sync
  mkfs.fat -F 32 "$efi_partition"
  mkswap "$swap_partition"
  mkfs.ext4 "$root_partition"
  sync

  # Checks rootfs size
  local root_size_GiB=$(df -BG "$root_partition" | awk 'END {print $2}' | tr -d 'G')
  if [[ $root_size_GiB -le 1 ]]; then
    df -BG "$root_partition" | awk 'END {print $2}'
    error "Root filesystem has size less then 1 GiB"
  fi
}

mount_partitions() {
  title "Mounting partitions"
  mount "$root_partition" "$new_root"
  mkdir -p "$new_root"/boot/
  mount "$efi_partition" "$new_root"/boot/
  swapon "$swap_partition"
}

umount_partitions() {
  title "Umounting partitions"
  umount -R "$new_root"
  swapoff "$swap_partition"
}

install_packages() {
  # Installs packages
  title "Installing rootfs packages"
  pacstrap -c -K "$new_root" base linux sudo "${additional_packages[@]}"
}

install_systemd_loader() {
  # Installs systemd-boot
  title "Installing systemd loader"
  arch-chroot "$new_root" bootctl install

  cat > "$new_root"/boot/loader/entries/arch.conf <<EOF
  title Arch Linux
  linux /vmlinuz-linux
  initrd /initramfs-linux.img
  options root=PARTUUID=$rootfs_uuid $kernel_options
EOF
}

configure() {
  title "Configuring new system"

  # Generates mount table based on current "$new_root" mounts.
  genfstab -U "$new_root" >> "$new_root"/etc/fstab

  # Sets localzone
  ln -sf /usr/share/zoneinfo/$timezone "$new_root"/etc/localtime

  # Sets mirrors
  echo "$mirrors" >> "$new_root"/etc/pacman.d/mirrorlist

  # Configure locales
  while read locale; do
    uncomment_line "$locale" "$new_root/etc/locale.gen"
  done <<< "$locales"

  main_locale="$(echo "$locales" | head -1)"
  echo "LANG=$main_locale" > "$new_root"/etc/locale.conf

  arch-chroot "$new_root" locale-gen

  # Synchronizes system clocks
  arch-chroot "$new_root" hwclock --systohc

  # Sets hostname
  echo "$hostname" > "$new_root"/etc/hostname

  change_password_chroot() {
    local user="$1"
    local password="${2:-}"

    if [[ -n $password ]]; then
      # Sets password
      arch-chroot "$new_root" bash -c "echo -e '$password\n$password' | passwd '$user'"
    else
      # Deletes password
      arch-chroot "$new_root" passwd -d "$user"
    fi
  }

  # Sets root password
  change_password_chroot root "${root_password:-}"

  # Creates user
  if [[ -n ${user_name:-} ]]; then
    arch-chroot "$new_root" useradd \
      --groups wheel \
      --create-home "$user_name"
    change_password_chroot "$user_name" "${user_password:-}"

    # Settings sudo up
    sudoers="$new_root"/etc/sudoers
    uncomment_line "%wheel ALL=(ALL:ALL) ALL" "$sudoers"
    if [[ ${paswordless_sudo:-} == "true" ]]; then
      uncomment_line "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" "$sudoers"
    fi
  fi
}

run_user_script() {
  if [[ -z "$post_bash_script" ]]; then
    return 0
  fi

  title "Running user script"
  arch-chroot "$new_root" /bin/bash <<< "$post_bash_script" || {
    error "User script exits with error"
  }
}


locales="$(remove_empty_lines_and_empty_space "$locales")"
mirrors="$(remove_empty_lines_and_empty_space "$mirrors")"
new_root="/mnt"
rootfs_uuid="$(uuidgen)"

inspect_initial_assertions

setup_mirrors

part_device

trap umount_partitions EXIT
mount_partitions

install_packages

install_systemd_loader
configure
run_user_script
sync
