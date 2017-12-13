# Monter les dossiers utilisés par libvirt

mount -t zfs ROT/SHARED/libvirt/etc /etc/libvirt -o defaults,noatime,nodiratime
mount -t zfs ROT/SHARED/libvirt/var_lib /var/lib/libvirt -o defaults,noatime,nodiratime
#mount -t zfs SSD/SHARED/libvirt/qemu_save /var/lib/libvirt/qemu/save -o defaults,noatime,nodiratime
mount -t zfs SSD/SHARED/hvm /var/lib/hvm -o defaults,noatime,nodiratime

zfs mount -a
