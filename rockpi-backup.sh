#!/bin/bash
set -e
AUTHOR="Akgnah <1024@setq.me>"
VERSION="0.15.0"
SCRIPT_NAME=$(basename $0)
BOOT_MOUNT=$(mktemp -d)
ROOT_MOUNT=$(mktemp -d)
DEVICE=/dev/$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p' | cut -b 1-7)


check_root() {
  if [ $(id -u) != 0 ]; then
    echo -e "${SCRIPT_NAME} needs to be run as root.\n"
    exit 1
  fi
}


get_option() {
  exclude=""
  label=rootfs
  model=rockpi4
  OLD_OPTIND=$OPTIND
  while getopts "o:e:m:l:t:uh" flag; do
    case $flag in
      o)
        output="$OPTARG"
        ;;
      e)
        exclude="${exclude} --exclude ${OPTARG}"
        ;;
      m)
        model="$OPTARG"
        ;;
      l)
        label="$OPTARG"
        ;;
      t)
        target="$OPTARG"
        ;;
      u)
        $OPTARG
        unattended="1"
        ;;
      h)
        $OPTARG
        print_help="1"
        ;;
    esac
  done
  OPTIND=$OLD_OPTIND
}


confirm() {
  if [ "$unattended" == "1" ]; then
    return 0
  fi
  printf "\n%s [Y/n] " "$1"
  read resp
  if [ "$resp" == "Y" ] || [ "$resp" == "y" ] || [ "$resp" == "yes" ]; then
    return 0
  fi
  if [ "$2" == "abort" ]; then
    echo -e "Abort.\n"
    exit 0
  fi
  if [ "$2" == "clean" ]; then
    rm "$3"
    echo -e "Abort.\n"
    exit 0
  fi
  return 1
}


install_tools() {
  commands="rsync parted gdisk kpartx mkfs.vfat losetup"
  packages="rsync parted gdisk kpartx dosfstools util-linux 96boards-tools-common"

  idx=1
  need_packages=""
  for cmd in $commands; do
    if ! command -v $cmd > /dev/null; then
      pkg=$(echo "$packages" | cut -d " " -f $idx)
      printf "%-30s %s\n" "Command not found: $cmd", "package required: $pkg"
      need_packages="$need_packages $pkg"
    fi
    ((++idx))
  done

  if [ "$need_packages" != "" ]; then
    confirm "Do you want to apt-get install the packages?" "abort"
    apt-get update
    apt-get install -y --no-install-recommends $need_packages
    echo '--------------------'
  fi
}


gen_partitions() {
  boot_size=1048576
  loader1_size=8000
  reserved1_size=128
  reserved2_size=8192
  loader2_size=8192
  atf_size=8192

  system_start=0
  loader1_start=64
  reserved1_start=$(expr ${loader1_start} + ${loader1_size})
  reserved2_start=$(expr ${reserved1_start} + ${reserved1_size})
  loader2_start=$(expr ${reserved2_start} + ${reserved2_size})
  atf_start=$(expr ${loader2_start} + ${loader2_size})
  boot_start=$(expr ${atf_start} + ${atf_size})
  rootfs_start=$(expr ${boot_start} + ${boot_size})
}


gen_image_file() {
  if [ "$output" == "" ]; then
    output="${PWD}/${model}-backup-$(date +%y%m%d-%H%M).img"
  else
    if [ "${output:(-4)}" == ".img" ]; then
      mkdir -p $(dirname $output)
    else
      mkdir -p "$output"
      output="${output%/}/${model}-backup-$(date +%y%m%d-%H%M).img"
    fi
  fi

  rootfs_size=$(expr $(df -P | grep /$ | awk '{print $3}') \* 5 / 4 \* 1024)
  backup_size=$(expr \( $rootfs_size + \( ${rootfs_start} + 35 \) \* 512 \) / 1024 / 1024)

  dd if=/dev/zero of=${output} bs=1M count=0 seek=$backup_size status=none
  parted -s ${output} mklabel gpt
  parted -s ${output} unit s mkpart loader1 ${loader1_start} $(expr ${reserved1_start} - 1)
  parted -s ${output} unit s mkpart loader2 ${loader2_start} $(expr ${atf_start} - 1)
  parted -s ${output} unit s mkpart trust ${atf_start} $(expr ${boot_start} - 1)
  parted -s ${output} unit s mkpart boot ${boot_start} $(expr ${rootfs_start} - 1)
  parted -s ${output} set 4 boot on
  parted -s ${output} -- unit s mkpart rootfs ${rootfs_start} -34s

  LOADER1_UUID=$(blkid -o export /dev/mmcblk1p1 | grep ^PARTUUID | sed 's/PARTUUID=//')
  LOADER2_UUID=$(blkid -o export /dev/mmcblk1p2 | grep ^PARTUUID | sed 's/PARTUUID=//')
  TRUST_UUID=$(blkid -o export /dev/mmcblk1p3 | grep ^PARTUUID | sed 's/PARTUUID=//')
  BOOT_UUID=$(blkid -o export /dev/mmcblk1p4 | grep ^PARTUUID | sed 's/PARTUUID=//')
  ROOTFS_UUID=$(blkid -o export /dev/mmcblk1p5 | grep ^PARTUUID | sed 's/PARTUUID=//')
  gdisk ${output} > /dev/null << EOF
x
c
1
${LOADER1_UUID}
c
2
${LOADER2_UUID}
c
3
${TRUST_UUID}
c
4
${BOOT_UUID}
c
5
${ROOTFS_UUID}
w
y
q
EOF
}


check_avail_space() {
  output_=${output}
  while true; do
    store_size=$(df -BM | grep "$output_\$" | awk '{print $4}' | sed 's/M//g')
    if [ "$store_size" != "" ] || [ "$output_" == "\\" ]; then
      break
    fi
    output_=$(dirname $output_)
  done

  if [ $(expr ${store_size} - ${backup_size}) -lt 64 ]; then
    rm ${output}
    echo -e "No space left on ${output_}\nAborted.\n"
    exit 1
  fi

  return 0
}


backup_image() {
  loopdevice=$(losetup -f --show $output)
  mapdevice="/dev/mapper/$(kpartx -va $loopdevice | sed -E 's/.*(loop[0-9]+)p.*/\1/g' | head -1)"
  sleep 2  # waiting for kpartx
  VFAT_UUID=$(blkid -o export /dev/mmcblk1p4 | grep ^UUID | sed 's/UUID=//' | sed 's/-//')
  EXT4_UUID=$(blkid -o export /dev/mmcblk1p5 | grep ^UUID | sed 's/UUID=//')
  mkfs.vfat -n boot ${mapdevice}p4 -i ${VFAT_UUID}
  mkfs.ext4 -L ${label} ${mapdevice}p5 -U ${EXT4_UUID}
  mount -t vfat ${mapdevice}p4 ${BOOT_MOUNT}
  mount -t ext4 ${mapdevice}p5 ${ROOT_MOUNT}

  dd if=${DEVICE}p1 of=${output} seek=${loader1_start} conv=notrunc
  dd if=${DEVICE}p2 of=${output} seek=${loader2_start} conv=notrunc
  dd if=${DEVICE}p3 of=${output} seek=${atf_start} conv=notrunc

  rsync --force -rltWDEgop --delete --stats --progress //boot/ ${BOOT_MOUNT}
  systemctl enable resize-assistant.service
  rsync --force -rltWDEgop --delete --stats --progress $exclude \
    --exclude "$output" \
    --exclude '.gvfs' \
    --exclude '/boot' \
    --exclude '/dev' \
    --exclude '/media' \
    --exclude '/mnt' \
    --exclude '/proc' \
    --exclude '/run' \
    --exclude '/sys' \
    --exclude '/tmp' \
    --exclude 'lost\+found' \
    // $ROOT_MOUNT

  # special dirs
  for i in boot dev media mnt proc run sys; do
    if [ ! -d $ROOT_MOUNT/$i ]; then
      mkdir $ROOT_MOUNT/$i
    fi
  done

  if [ ! -d $ROOT_MOUNT/tmp ]; then
    mkdir $ROOT_MOUNT/tmp
    chmod a+w $ROOT_MOUNT/tmp
  fi

  sync
  umount $BOOT_MOUNT && rm -rf $BOOT_MOUNT
  umount $ROOT_MOUNT && rm -rf $ROOT_MOUNT
  losetup -d $loopdevice
  kpartx -d $loopdevice

  echo -e "\nBackup done, the file is ${output}"
}


target_expand() {
  systemctl enable resize-assistant.service
}


usage() {
  echo -e "Usage:\n  sudo ./${SCRIPT_NAME} [-o path|-e pattern|-m model|-l label|-t target|-u]"
  echo '    -o specify output position, default is $PWD'
  echo '    -e exclude files matching pattern for rsync'
  echo '    -m specify model, rockpi4, default is rockpi4'
  echo '    -l specify a volume label for rootfs, default is rootfs'
  echo '    -t specify target, backup or expand, default is backup'
  echo '    -u unattended, no need to confirm in the backup process'
}


main() {
  check_root

  echo -e "Welcome to rockpi-backup.sh, part of the ROCK Pi toolkit.\n"
  echo -e "  Enter ${SCRIPT_NAME} -h to view help."
  echo -e "  For a description and example usage, see the README.md at:
    https://rock.sh/rockpi-toolbox \n"
  echo '--------------------'

  if [ "$target" == "expand" ]; then
    target_expand
  else
    install_tools
    gen_partitions
    gen_image_file
    check_avail_space

    printf "The backup file will be saved at %s\n" "$output"
    printf "After this operation, %s MB of additional disk space will be used.\n" "$backup_size"
    confirm "Do you want to continue?" "clean" "$output"

    backup_image
  fi
}

get_option $@
if [ "$print_help" == "1" ]; then
  usage
else
  main
fi
# end
