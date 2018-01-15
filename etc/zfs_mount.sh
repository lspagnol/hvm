# Monter les dossiers utilisés par libvirt

# Points de montage "legacy"
mount -t zfs ROT/SHARED/libvirt/etc /etc/libvirt -o defaults,noatime,nodiratime
mount -t zfs ROT/SHARED/libvirt/var_lib /var/lib/libvirt -o defaults,noatime,nodiratime

# Montage automatique
zfs mount -a
