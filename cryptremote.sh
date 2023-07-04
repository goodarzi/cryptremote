#!/usr/bin/env bash


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