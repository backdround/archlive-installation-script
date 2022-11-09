#!/usr/bin/env bash
set -euo pipefail


source "$(dirname $0)/utils.sh"
source "$(dirname $0)/config"


inspect_initial_assertions() {
  echo "Checking internet"
  assert_internet "Internet isn't available"

  echo "Checking EFI"
  assert_efi "EFI not found"

  echo "Checking current environment"
  assert_live_image "Launching environment must be a live image"

  echo "Checking set variables"

  assert_block_device "$device" "Flash device must be a block device"

  assert_not_empty "$hostname" "hostname name must be set"
  assert_size "$swap_size" "swap_size has incorrect format"
  check_not_empty "$kernel_options" "Kernel options are empty. Are you sure?"

  check_timezone "$timezone" "Unable to find given timezone in current environment"
  check_locales "$locales" "Unable to find given locale in current environment"
  check_mirrors "$mirrors" "Unable to parse format of mirror"
}

part_device() {
  # Parts device
  echo "\
  label: gpt
  start=2048, size=240M, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  size=$swap_size, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
  type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=$rootfs_uuid
  write
  " | sfdisk --wipe-partitions always --quiet "$device" | cat
  sync "$device"

  efi_partition="$(get_partition_path_by_number "$device" 1)"
  swap_partition="$(get_partition_path_by_number "$device" 2)"
  root_partition="$(get_partition_path_by_number "$device" 3)"

  # Makes filesystems
  mkfs.fat -F 32 "$efi_partition"
  mkswap "$swap_partition"
  mkfs.ext4 "$root_partition"

  # Checks rootfs size
  local root_size_GiB=$(df -BG "$root_partition" | awk 'END {print $2}' | tr -d 'G')
  if [[ $root_size_GiB -le 1 ]]; then
    df -BG "$root_partition" | awk 'END {print $2}'
    error "Root filesystem has size less then 1 GiB"
  fi
}

mount_devices() {
  mount "$root_partition" /mnt
  mkdir -p /mnt/boot/
  mount "$efi_partition" /mnt/boot/
  swapon "$swap_partition"
}

umount_devices() {
  umount -R /mnt
  swapoff "$swap_partition"
}

install_packages() {
  # Sets users cache directory
  if [[ -n "$pacman_cache" ]]; then
    sed -i "s|^#CacheDir.*|CacheDir = $pacman_cache|g" /etc/pacman.conf
  fi

  # Installs packages
  pacstrap -c -K /mnt base linux linux-firmware $additional_packages
}

install_systemd_loader() {
  # Installs systemd-boot
  arch-chroot /mnt <<< "bootctl install"

  cat > /mnt/boot/loader/entries/arch.conf <<EOF
  title Arch Linux
  linux /vmlinuz-linux
  initrd /initramfs-linux.img
  options root=PARTUUID=$rootfs_uuid $kernel_options
EOF
}

configure() {

  # Generates mount table based on current /mnt mounts.
  genfstab -U /mnt >> /mnt/etc/fstab

  # Sets localzone
  ln -sf /usr/share/zoneinfo/$timezone /mnt/etc/localtime

  # Sets mirrors
  echo "$mirrors" >> /mnt/etc/pacman.d/mirrorlist

  # Configure locales
  while read locale; do
    sed -i "s/#$locale/$locale/g" /mnt/etc/locale.gen
  done <<< "$locales"

  main_locale="$(echo "$locales" | head -1)"
  echo "LANG=$main_locale" > /mnt/etc/locale.conf

  arch-chroot /mnt <<< "locale-gen"

  # Synchronizes system clocks
  arch-chroot /mnt <<< "hwclock --systohc"

  # Sets hostname
  echo "$hostname" > /mnt/etc/hostname

  change_password_chroot() {
    local user="$1"
    local password="${2:-}"

    if [[ -n $password ]]; then
      # Sets password
      arch-chroot /mnt <<< \
        "echo -e \"$password\n$password\" | passwd \"$user\""
    else
      # Deletes password
      arch-chroot /mnt <<< "passwd -d \"$user\""
    fi
  }

  # Sets root password
  change_password_chroot root "${password:-}"

  # Creates user
  if [[ -n ${user_name:-} ]]; then
    arch-chroot /mnt <<< "useradd --create-home \"$user_name\""
    change_password_chroot "$user_name" "${user_password:-}"
  fi
}


locales="$(remove_empty_lines_and_empty_space "$locales")"
mirrors="$(remove_empty_lines_and_empty_space "$mirrors")"
rootfs_uuid="$(uuidgen)"
inspect_initial_assertions

part_device

trap umount_devices EXIT
mount_devices

install_packages

install_systemd_loader
configure
sync
