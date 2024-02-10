#!/usr/bin/env bash
set -e
# set -x

usage () {
  if [ "$#" -eq "0" ]; then
    usage mountimage cryptloop umountall writeimage cryptunlock chrootmount bootconfig fstabconfig dbinitramfs initramfs installinitramfs updateinitramfs firstrun
    return 0
  fi
  echo "Usage: "
  for arg in "$@"; do
    case "$arg" in
      mountimage)
        echo "  $0 mountimage OSIMAGE"
        ;;
      cryptloop)
        echo "  $0 cryptloop OSIMAGE EXTENDSIZE KEYFILE CRYPTPASS CRYPTMAP"
        ;;
      writeimage)
        echo "  $0 writeimage OSIMAGE DEVICESD"
        ;;
      cryptunlock)
        echo "  $0 cryptunlock cryptimg cryptmapper"
        ;;
      chrootmount)
        echo "  $0 chrootmount bootimg rootimg mntpath [cryptmapper] [keyfile]"
        ;;
      installinitramfs)
        echo "  $0 installinitramfs mntpath dbpubkeyexportpath"
        ;;
      dbinitramfs)
        echo "  $0 dbinitramfs mntpath SERVERPUBKEY USERPUBKEY"
        ;;
      bootconfig)
        echo "  $0 bootconfig mntpath cryptmap"
        ;;
      fstabconfig)
        echo "  $0 fstabconfig mntpath cryptmap"
        ;;
      initramfs)
        echo "  $0 initramfs mntpath cryptremotepath"
        ;;
      updateinitramfs)
        echo "  $0 updateinitramfs mntpath"
        ;;
      firstrun)
        echo "  $0 firstrun mntpath firstrunpath"
        ;;
      umountall)
        echo "  $0 umountall mntpath"
        ;;
    esac
  done
  }

# get_label IMG
get_label() {
    isblkid=$(blkid $1) || return 1
    echo $(echo $isblkid | sed 's/.*LABEL="\(\w*\)".*/\1/')
}

fstype() {
    isblkid=$(blkid $1) || return 1
    echo $(echo $isblkid | sed 's/.*TYPE="\(\w*\)".*/\1/')
}

get_directory(){
    if [ -d "$1" ];then
        return 0
    else
        echo "Invalid Directory: $1"
        return 1
    fi
}

get_file(){
    if [ -f "$1" ];then
        return 0
    else
        echo "Invalid File: $1"
        return 1
    fi
}

fstypecheck(){
    fstypeimg=$(fstype $1) || return 1
    [[ fstypeimg=="$2" ]] && echo $1
}

# inputs: OSIMAGE
# outputs: loopimages
mountimage(){
    loop=$(losetup -l -n -O name -j $1)
    if test -z ${loop} ; then
        loop=$(losetup -f)
        losetup -Pf ${1}
    fi
    for p in ${loop}p*; do
        echo $p
    done
}

# cryptloop OSIMAGE IMGEXTENDSIZE KEYFILE CRYPTPASS CRYPTMAP
cryptloop(){
    OSIMAGE=$1
    IMGEXTENDSIZE=$2
    KEYFILE=$3
    CRYPTPASS=$4
    CRYPTMAP=${5:-"cryptmap0"}
    ROOTIMAGE=""
    mountimage $OSIMAGE
    for p in $(mountimage $1); do
        blkid -t TYPE=ext4 $p && ROOTIMAGE=$p
    done
    imgsize=$(partx ${OSIMAGE} -o SIZE -brg -n2)
    extendsize=$((${IMGEXTENDSIZE}*1024*1024)) 
    newsize=$((${imgsize}+${extendsize}))
    cloneroot=$(dirname $OSIMAGE)/$(basename "${OSIMAGE%.*}")-$(blkid -p --match-tag LABEL --output value $ROOTIMAGE).img
    dd if=${ROOTIMAGE} of=$cloneroot status=progress
    losetup -D
    parted ${OSIMAGE} rm 2
    truncate -s +${extendsize} ${OSIMAGE}
    endsector=$(partx ${OSIMAGE} -o END -rg -n1)
    startsector=$((${endsector}+1))
    parted -a minimal -s ${OSIMAGE} mkpart primary ${startsector}s 100%
    mountimage $OSIMAGE
    test -e ${KEYFILE} || dd bs=512 count=4 if=/dev/random of=${KEYFILE} iflag=fullblock && chmod -v 0400 ${KEYFILE} && chown root:root ${KEYFILE}
    cryptsetup -q -v -y --pbkdf pbkdf2 --cipher aes-cbc-essiv:sha256 --key-size 256 luksFormat ${ROOTIMAGE} ${KEYFILE}
    echo -n ${CRYPTPASS} | cryptsetup -q -v luksAddKey --key-file=${KEYFILE} ${ROOTIMAGE}
    test -e /dev/mapper/${CRYPTMAP} || cryptsetup luksOpen ${ROOTIMAGE} ${CRYPTMAP} --key-file ${KEYFILE}
    dd if=$cloneroot of=/dev/mapper/${CRYPTMAP} status=progress
    resize2fs /dev/mapper/${CRYPTMAP}
}

# umountall mntpath
umountall() {
    if mntsrc=$(findmnt -n -o SOURCE $1 ); then
        echo "Mount source : $mntsrc"
        umount -R $1
        if [ "$(dirname $mntsrc)" = "/dev/mapper" ]; then
            cryptsrc=$(cryptsetup status $mntsrc | grep device: | awk '{print $2}')
            cryptsetup luksClose $mntsrc
            echo "Luks close : $mntsrc"
            mntsrc=$cryptsrc
        fi

        if backfile=$(losetup -n -a -O BACK-FILE $mntsrc); then
            losetup -d $(losetup -n -a -O NAME $mntsrc)
            echo "$mntsrc detached from $backfile"
        else
            echo " Umount $1 Successfully."
        fi
    else
        echo "Mount not found."
    fi
}

# writeimage OSIMAGE DEVICESD
writeimage() {
    if ! get_file $1; then return 1; fi
    DEVICESD=$2
    loop=$(losetup -l -n -O name -j $1)
    if [ -n "$loop" ];then
        for i in $loop"p"*;do
            if cryptsetup isLuks $i; then
                uuid=$(blkid --match-tag UUID --output value /dev/loop0p2 | tr -d -)
                if cryptmap=$(find  /dev/disk/by-id/ -iname "dm-uuid*$uuid*") && -n "$cryptmap"; then
                    test targetmnt=$(findmnt -n -o TARGET $cryptmap) && umount -R $targetmnt
                    cryptsetup luksClose $cryptmap
                fi
            fi
        done
        losetup -d $loop
    fi
    umountall $2

    dd bs=1M if="$1" of=$2 status=progress conv=fsync
}

# cryptunlock cryptimg cryptmapper
cryptunlock() {
    cryptimg=$1
    cryptmapper=${2:-"cryptmap0"}
    if test -e /dev/mapper/$cryptmapper; then
        if testmount=$(findmnt /dev/mapper/$cryptmapper -o target -n); then umount -d -R $testmount;fi 
        cryptsetup luksClose $cryptmapper
    fi
    test -v 3 && cryptsetup -q luksOpen $cryptimg $cryptmapper --key-file $3 || cryptsetup luksOpen $cryptimg $cryptmapper
    test -b /dev/mapper/$cryptmapper && echo /dev/mapper/$cryptmapper || exit 2
}

dosimg() {
    loop=$(losetup -l -n -O name -j $1 | head -n 1)
    if test -z ${loop} ; then
        loop=$(losetup -f)
        losetup -Pf $1
    fi
    for p in ${loop}p*; do
        echo $p
    done
}

gptimg() {
    for p in ${1}*; do
        echo $p
    done
}

# rootcheck rootimg cryptmapper
rootcheck() {
    fstyperootimg=$(fstype $1) || return 1
    case $fstyperootimg in
        gpt)
            for i in $(gptimg $1); do
                sleep 1
                rootcheck $i $2 $3
            done
        ;;
        dos)
            for i in $(dosimg $1); do
                sleep 1
                rootcheck $i $2 $3
            done
        ;;
        ext4)
            echo $1
        ;;
        crypto_LUKS)
            unlockedimg=$(cryptunlock $1 $2 $3)
            echo $unlockedimg
        ;;
    esac
}

# bootcheck bootimg
bootcheck() {
    fstypebootimg=$(fstype $1) || return 1
    case $fstypebootimg in
        "gpt")
            for i in $(gptimg $1); do
                sleep 1
                bootcheck $i
            done
        ;;
        "dos")
            for i in $(dosimg $1); do
                sleep 1
                bootcheck $i
            done
        ;;
        "vfat")
            echo $1
        ;;
    esac
}

get_bootpath(){
    test -z "$1" && return 1
    local bootpath=$(sed -rn '/boot/s/^(\S*)\s*([a-zA-Z\/]*)\s*(\w*)\s.*/\2/p' $1/etc/fstab)
    if [ -n "$bootpath" ]; then
        echo $bootpath
    else
        return 1
    fi
}

# chrootmount bootimg rootimg mntpoint [cryptmapper] [keyfile]
chrootmount() {
    if ! get_file $1; then return 1; fi
    if ! get_file $2; then return 1; fi
    if ! get_directory $3; then return 1; fi

    bootimgcheck=$(bootcheck $1)
    rootimgcheck=$(rootcheck $2 $4 $5)
    if  [[ -n bootimgcheck && -v rootimgcheck ]]; then
        test -e ${3} || mkdir -v -p ${3}
        findmnt -R ${3} && umount -d -R ${3}
        findmnt ${3} || mount $rootimgcheck ${3}
        local bootpath=${3}$(get_bootpath ${3})
        findmnt $bootpath || mount $bootimgcheck $bootpath
        findmnt ${3}/proc || mount -t proc none ${3}/proc
        findmnt ${3}/sys || mount -t sysfs none ${3}/sys
        findmnt ${3}/dev || mount -o bind /dev ${3}/dev
        findmnt ${3}/dev/pts || mount -o bind /dev/pts ${3}/dev/pts
    fi
}

# bootconfig mntpath cryptmap
bootconfig(){
    cryptdev=$(cryptsetup status $2 | sed -rn '/device:/s/.*device:\s*(\S*).*/\1/p')
    cryptuuid=$(blkid --match-tag UUID --output value $cryptdev)
    luksUUID
    # if [ -z ${ROOTIMAGE} ]; then mountimage; fi
    test -z $1 && return 1
    local bootpath=$1$(get_bootpath $1)
    sed -i -E "s/(.*root=)(\S*)(\s.*)/\1\/dev\/mapper\/$2 cryptdevice=UUID=$cryptuuid:$2\3/" $bootpath/cmdline.txt
    cat $bootpath/cmdline.txt
}

# fstabconfig mntpath cryptmap
fstabconfig(){
    test -z "$1" && return 1
    cryptdev=$(cryptsetup status $2 | sed -rn '/device:/s/.*device:\s*(\S*).*/\1/p')
    cryptuuid=$(blkid --match-tag UUID --output value $cryptdev)
    bootdev=$(findmnt "$1$(get_bootpath $1)" | sed -nr '2s/\S*\s*(\S*).*/\1/p')
    bootuuid=$(blkid --match-tag UUID --output value $bootdev)
    cp ${1}/etc/fstab ./fstab_backup
    sed -i -r -e "/boot/s/^\S*(\s*.*)/UUID=$bootuuid\1/" -e "/\s\/\s/s/^\S*(\s*.*)/\/dev\/mapper\/$2\1/" ${1}/etc/fstab
    cat ${1}/etc/fstab
    echo -e ${2}'\t UUID='$cryptuuid'\t none\t luks' > ${1}/etc/crypttab
    cat ${1}/etc/crypttab
}

# dbinitramfs rootfolder SERVERPUBKEY USERPUBKEY
dbinitramfs(){
    if (( $# < 2 )); then
        echo "usage dbinitramfs rootfolder SERVERPUBKEY USERPUBKEY"
        return 1
    fi
    if [[ -d $1 ]]; then
    test -e $1/etc/dropbear/initramfs || mkdir -pv $1/etc/dropbear/initramfs/
    test -e $1/etc/dropbear/initramfs/authorized_keys || touch $1/etc/dropbear/initramfs/authorized_keys
    chmod 600 $1/etc/dropbear/initramfs/authorized_keys
    echo $2 > $1/etc/dropbear/initramfs/authorized_keys
    echo $3 >> $1/etc/dropbear/initramfs/authorized_keys
    cat $1/etc/dropbear/initramfs/authorized_keys
    else 
        echo "Invalid Directory: $1"
        return 1
    fi
}

# installinitramfs ROOTMOUNT dbpubkeyexportpath
installinitramfs() {
    ROOTMOUNT=${1:-"${ROOTMOUNT}"}
    dbpubkeyexportpath=${2:-$dbpubkeyexportpath}
    env LANG=C chroot ${ROOTMOUNT} apt update 
    env LANG=C chroot ${ROOTMOUNT} apt upgrade -y
    env LANG=C chroot ${ROOTMOUNT} apt install -y busybox cryptsetup dropbear-initramfs cryptsetup-initramfs
    env LANG=C chroot ${ROOTMOUNT} dropbearkey -y -f /etc/dropbear/initramfs/dropbear_ed25519_host_key | grep "^ssh-ed25519 " > $dbpubkeyexportpath
    cp ${ROOTMOUNT}/etc/dropbear/initramfs/*key ./
}


# ./cryptremote.sh initramfs /mnt/chroot1 ./authbach
# initramfs ROOTMOUNT cryptremotepath
initramfs(){
test -z "$1" && return 1
test -z "$2" && return 1
grep -q 'IP="dhcp"' $1/etc/initramfs-tools/initramfs.conf || echo 'IP="dhcp"' >> $1/etc/initramfs-tools/initramfs.conf
grep -q 'dm_crypt' $1/etc/initramfs-tools/modules || echo dm_crypt >> $1/etc/initramfs-tools/modules
grep -q 'CRYPTSETUP=y' $1/etc/cryptsetup-initramfs/conf-hook || echo CRYPTSETUP=y >> $1/etc/cryptsetup-initramfs/conf-hook

cp -v $2 $1/etc/initramfs-tools/scripts/init-premount/cryptremote
chmod +x $1/etc/initramfs-tools/scripts/init-premount/cryptremote

cat << _EOF_ > $1/etc/initramfs-tools/hooks/zz-dbclient
#!/bin/sh
set -e

PREREQ="dropbear"
prereqs()
{
     echo "\$PREREQ"
}
 
case \$1 in
prereqs)
     prereqs
     exit 0
     ;;
esac

. /usr/share/initramfs-tools/hook-functions

# Begin real processing below this line

copy_exec /usr/bin/dbclient /bin

LIB=/lib/\$(uname -m)-linux-gnu
mkdir -p "\$DESTDIR/\$LIB"
cp \$LIB/libnss_dns.so.2 \\
  \$LIB/libnss_files.so.2 \\
  \$LIB/libresolv.so.2 \\
  \$LIB/libc.so.6 \\
  "\${DESTDIR}/\$LIB"
echo nameserver 8.8.8.8 > "\${DESTDIR}/etc/resolv.conf"
_EOF_

chmod +x $1/etc/initramfs-tools/hooks/zz-dbclient
}

# firstrun mntpath firstrunpath
firstrun(){
    if ! get_directory $1; then return 1; fi
    if ! get_file $2; then return 1; fi
    bootpath=$1$(get_bootpath $1)
    cp $2 $1/root/firstrun2.sh
    chmod +x $1/root/firstrun2.sh
    boot_option='systemd.run=\/root\/firstrun2.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target'
    sed -i 's/ systemd.run.*//g' $bootpath/cmdline.txt
    sed -i "/\(systemd.run=.*\s\)/q 0;s/\(.*\)/\1 $boot_option/" $bootpath/cmdline.txt
    cat $bootpath/cmdline.txt
}

# updateinitramfs mntpath
updateinitramfs(){
    env LANG=C chroot $1 update-initramfs -u 
}


if [ "$#" -eq 0 ]; then
  echo "No command specified"
  usage
  exit 1
fi

command="$1"; shift
case "$command" in
  mountimage|cryptloop|umountall|writeimage|cryptunlock|chrootmount|bootconfig|fstabconfig|dbinitramfs|initramfs|installinitramfs|updateinitramfs|firstrun)
    "$command" "$@"
    ;;
  *)
    echo "Unsupported command: $command"
    usage
    exit 1
    ;;
esac


