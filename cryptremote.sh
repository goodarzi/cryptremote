#!/usr/bin/env bash
set -e
#set -x

REMOTEFORWARDP=${REMOTEFORWARDP:-"2220"}
REMOTEADDR=${REMOTEADDR:-"example.com"}
REMOTEPORT=${REMOTEPORT:-"22"}
REMOTEUSER=${REMOTEUSER:-"remoteuser"}
LOCALPORT=${LOCALPORT:-"22"}
OSIMAGE=${OSIMAGE:-"/usr/src/2023-05-03-raspios-bullseye-arm64-lite.img"}
ROOTMOUNT=${ROOTMOUNT:-"/mnt/cryptroot"}
ROOTIMAGE=${ROOTIMAGE:-"/dev/loop0p2"}
BOOTIMAGE=${BOOTIMAGE:-"/dev/loop0p1"}
CRYPTMAP=${CRYPTMAP:-"crypt"}
SERVERPUBKEY=${SERVERPUBKEY:-"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI.... remote@example.com"}
USERPUBKEY=${USERPUBKEY:-"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI.... user@example.local"}

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



initramfs(){
cat << _EOF_ > ${ROOTMOUNT}/etc/initramfs-tools/hooks/zz-cryptsetup 
#!/bin/sh
set -e

PREREQ=""
prereqs()
{
	echo "\${PREREQ}"
}

case "\${1}" in
	prereqs)
		prereqs
		exit 0
		;;
esac

. /usr/share/initramfs-tools/hook-functions

mkdir -p \${DESTDIR}/cryptroot || true
cat /etc/crypttab >> \${DESTDIR}/cryptroot/crypttab
cat /etc/fstab >> \${DESTDIR}/cryptroot/fstab
cat /etc/crypttab >> \${DESTDIR}/etc/crypttab
cat /etc/fstab >> \${DESTDIR}/etc/fstab

_EOF_

chmod +x ${ROOTMOUNT}/etc/initramfs-tools/hooks/zz-cryptsetup

grep -q dm_crypt ${ROOTMOUNT}/etc/initramfs-tools/modules || echo dm_crypt >> ${ROOTMOUNT}/etc/initramfs-tools/modules

echo CRYPTSETUP=y >> ${ROOTMOUNT}/etc/cryptsetup-initramfs/conf-hook

cat << _EOF_ > ${ROOTMOUNT}/etc/initramfs-tools/unluks.sh
#!/bin/sh

export PATH='/sbin:/bin:/usr/sbin:/usr/bin'

if [ \${1+1} ]; then
    echo -e \$1'\n' | cryptsetup luksOpen /dev/disk/by-uuid/${CRYPTUUID} crypt
else
    while true; do
        test -e /dev/mapper/${CRYPTMAP} && break
        cryptsetup luksOpen /dev/disk/by-uuid/${CRYPTUUID} crypt
        [ \$? -eq 0 ] && sleep 2 || exit 1
    done
fi

if test -e /dev/mapper/${CRYPTMAP}; then
    /scripts/local-top/cryptroot
    for i in \$(ps aux | grep 'cryptroot' | grep -v 'grep' | awk '{print \$1}'); do kill -9 \$i; done
    for i in \$(ps aux | grep 'askpass' | grep -v 'grep' | awk '{print \$1}'); do kill -9 \$i; done
    for i in \$(ps aux | grep 'ask-for-password' | grep -v 'grep' | awk '{print \$1}'); do kill -9 \$i; done
    for i in \$(ps aux | grep 'dbclient' | grep -v 'grep' | awk '{print \$1}'); do kill -9 \$i; done
    for i in \$(ps aux | grep 'authback' | grep -v 'grep' | awk '{print \$1}'); do kill -9 \$i; done
    for i in \$(ps aux | grep '\\-sh' | grep -v 'grep' | awk '{print \$1}'); do kill -9 \$i; done
    exit 0
fi
exit 1

_EOF_

chmod +x ${ROOTMOUNT}/etc/initramfs-tools/unluks.sh

cat << _EOF_ > ${ROOTMOUNT}/etc/initramfs-tools/scripts/init-premount/authback
#!/bin/sh

PREREQ="dropbear"
prereqs()
{
	echo "\${PREREQ}"
}
 
case "\${1}" in
	prereqs)
		prereqs
		exit 0
		;;
esac

. /scripts/functions

check_internet(){
	if ping -c 1 google.com > /dev/null 2>&1; then
	    echo "online"
	else
	    echo "offline"
	fi
}

create_link(){
	echo "LINK UP: Waiting for the network config"
	while :; do
		if [[ \$(check_internet) == "online" ]]; then 
			break
		fi
		sleep 2 || exit
	done
	echo "Creating link with server..."
	/sbin/ifconfig lo up
	dbclient -R ${REMOTEFORWARDP}:127.0.0.1:${LOCALPORT} ${REMOTEUSER}@${REMOTEADDR} -p ${REMOTEPORT} -i /root/.ssh/dropbear_ed25519_host_key -y -T 
}

watchdog(){
	echo "Watchdog started for network config"
	sleep 60

	if [[ \$(check_internet) == "online" ]]; then
		echo "Internet connection OK: stopping the short watchdog,"
		echo "...setting long watchdog (10 minutes)."
		sleep 600
	else
		echo "No internet connection, rebooting..."
		sleep 3
	fi
	test -e /dev/mapper/${CRYPTMAP} && exit 0 || /sbin/reboot -f || exit
}

create_link &
watchdog &

_EOF_

chmod +x ${ROOTMOUNT}/etc/initramfs-tools/scripts/init-premount/authback


cat << _EOF_ > ${ROOTMOUNT}/etc/initramfs-tools/hooks/zz-dbclient
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
SSH_DIR="\${DESTDIR}/root/.ssh/"
mkdir -p \$SSH_DIR
cp /etc/dropbear-initramfs/dropbear_ed25519_host_key \$SSH_DIR


LIB=/lib/aarch64-linux-gnu
mkdir -p "\$DESTDIR/\$LIB"
cp \$LIB/libnss_dns.so.2 \\
  \$LIB/libnss_files.so.2 \\
  \$LIB/libresolv.so.2 \\
  \$LIB/libc.so.6 \\
  "\${DESTDIR}/\$LIB"
echo nameserver 8.8.8.8 > "\${DESTDIR}/etc/resolv.conf"
copy_file shell /etc/initramfs-tools/unluks.sh /etc/unluks.sh

_EOF_

chmod +x ${ROOTMOUNT}/etc/initramfs-tools/hooks/zz-dbclient

cp ${ROOTMOUNT}/usr/share/initramfs-tools/scripts/init-premount/dropbear \
${ROOTMOUNT}/etc/initramfs-tools/scripts/init-premount/dropbear

sed -i '/^.*!= nfs/a sleep 5' ${ROOTMOUNT}/etc/initramfs-tools/scripts/init-premount/dropbear

}


${func} 