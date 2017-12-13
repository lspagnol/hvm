# Démonter les dossiers utilisés par libvirt

e=0

#for v in /LIBVIRT/ISO /LIBVIRT/ROT /LIBVIRT/SSD /var/lib/hvm /var/lib/libvirt/qemu/save /var/lib/libvirt /etc/libvirt ; do
for v in /LIBVIRT/ISO /LIBVIRT/ROT /LIBVIRT/SSD /var/lib/hvm /var/lib/libvirt /etc/libvirt ; do
	cat /proc/mounts |grep -q " ${v} " 
	if [ $? -eq 0 ] ; then
		umount ${v} 2>/dev/null
		cat /proc/mounts |grep -q " ${v} "
		if [ $? -eq 0 ] ; then
			ERROR "unable to umount '${v}'"
			e=1
		fi
	fi
done

[ ${e} -eq 0 ] && true || false
