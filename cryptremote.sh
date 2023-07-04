#!/usr/bin/env bash

mountimage(){
    existing_loop=$(losetup -j ${OSIMAGE})
    if [ -z ${existing_loop} ]; then
        loop=$(losetup -f)
        losetup -Pf ${OSIMAGE}
    fi
    ROOTIMAGE="${loop}p2"
    BOOTIMAGE="${loop}p1"
}


cryptloop(){
    existing_loop=$(losetup -j ${OSIMAGE})
    if [ -z ${existing_loop} ]; then
        loop=$(losetup -f)
        losetup -Pfr ${OSIMAGE}
    fi
    ROOTIMAGE="${loop}p2"
    BOOTIMAGE="${loop}p1"
    losetup -Pfr ${OSIMAGE}
    #fdisk -l  /dev/loop0
    imgsize=$(partx ${OSIMAGE} -o SIZE -brg -n2)
    extendsize=$((${imgsize}+256*1024*1024))
    osimagedir=$(dirname ${OSIMAGE})
    dd if=${ROOTIMAGE} of=${osimagedir}/rootfs.img status=progress
    losetup -D
    parted ${OSIMAGE} rm 2
    truncate -s ${extendsize} 
    parted -a minimal ${OSIMAGE} mkpart primary 0% 100%
    loop=$(losetup -f)
    losetup -Pf ${OSIMAGE}
    ROOTIMAGE="${loop}p2"
    BOOTIMAGE="${loop}p1"
    cryptsetup -v -y --pbkdf pbkdf2 --cipher aes-cbc-essiv:sha256 --key-size 256 luksFormat ${ROOTIMAGE}
    cryptsetup luksOpen ${ROOTIMAGE} ${CRYPTMAP}
    dd if="${osimagedir}/rootfs.img" of=/dev/mapper/${CRYPTMAP} status=progress
}


mountcrypt() {
    test -e ${ROOTIMAGE} || mount_img
    cryptsetup -v luksOpen ${ROOTIMAGE} ${CRYPTMAP}
    test -e ${ROOTMOUNT} || mkdir -v -p ${ROOTMOUNT}
    mount /dev/mapper/${CRYPTMAP} ${ROOTMOUNT}
    mount ${BOOTIMAGE} ${ROOTMOUNT}/boot/
    mount -t proc none ${ROOTMOUNT}/proc
    mount -t sysfs none ${ROOTMOUNT}/sys
    mount -o bind /dev ${ROOTMOUNT}/dev
    mount -o bind /dev/pts ${ROOTMOUNT}/dev/pts
}


setoption(){
    option=${1//\//\\/}
    value=${2//\//\\/}
    seperator=$3
    destfile=$4
    sed -Ei \
        -e "/${option}/{s/^(.*)(${option}[[:blank:]]*${seperator})([[:blank:]]*[^[:blank:]]*)(.*)/\1\2${value}\4/;q}" \
        -e "s/(.*)$/\1 ${option}${seperator}${value} /" ${destfile}
}


bootconfig(){
    set_option "root" "/dev/mapper/${CRYPTMAP}" "=" "${ROOTMOUNT}/boot/cmdline.txt"
    set_option "cryptdevice" "UUID=${CRYPTUUID}:${CRYPTMAP}" "=" "${ROOTMOUNT}/boot/cmdline.txt"
    cat "${ROOTMOUNT}/boot/cmdline.txt"
    
    bootconf="initramfs initramfs.gz followkernel"
    grep -q "${bootconf}" ${ROOTMOUNT}/boot/config.txt || echo ${bootconf} >> ${ROOTMOUNT}/boot/config.txt
    cat "${ROOTMOUNT}/boot/config.txt"
}


fstabconfig(){
    cp ${ROOTMOUNT}/etc/fstab ./fstab_backup
    echo -e 'proc\t /proc\t proc\t defaults\t 0\t 0' > ${ROOTMOUNT}/etc/fstab
    echo -e '/dev/mapper/'${CRYPTMAP}'\t /\t ext4\t errors=remount-ro\t 0\t 1' >> ${ROOTMOUNT}/etc/fstab
    # echo -e 'UUID='${EXT4UUID}'\t /\t ext4\t errors=remount-ro\t 0\t 1' >> ${ROOTMOUNT}/etc/fstab
    echo -e 'UUID='${BOOTUUID}'\t /boot\t vfat\t defaults\t 0\t 2' >> ${ROOTMOUNT}/etc/fstab
    cat ${ROOTMOUNT}/etc/fstab
    echo -e ${CRYPTMAP}'\t UUID='${CRYPTUUID}'\t none\t luks' > ${ROOTMOUNT}/etc/crypttab
    cat ${ROOTMOUNT}/etc/crypttab
}


dbinitramfs(){
    test -e ${ROOTMOUNT}/etc/dropbear-initramfs || mkdir -pv ${ROOTMOUNT}/etc/dropbear-initramfs/ 
    test -e ${ROOTMOUNT}/etc/dropbear-initramfs/authorized_keys || touch ${ROOTMOUNT}/etc/dropbear-initramfs/authorized_keys
    chmod 600 ${ROOTMOUNT}/etc/dropbear-initramfs/authorized_keys
    echo ${SERVERPUBKEY} > ${ROOTMOUNT}/etc/dropbear-initramfs/authorized_keys
    echo 'command="/etc/unluks.sh; exit" '${USERPUBKEY} >> ${ROOTMOUNT}/etc/dropbear-initramfs/authorized_keys
    cat ${ROOTMOUNT}/etc/dropbear-initramfs/authorized_keys
}