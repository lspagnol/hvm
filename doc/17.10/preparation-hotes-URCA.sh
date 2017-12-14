#!/bin/bash

# Préparation hôte
# Procédure testée sur Ubuntu 16.04 LTS

# Serveurs: Dell R630 + JBOD
# - 3 SDD/serveur       -> POOL 'SSD', 3 disques/RAIDZ
# - 5 rotatifs/serveur  -> POOL 'ROT', 5 disques/RAIDZ2
# - OU 12 rotatifs/JBOD -> POOL 'ROT', 3 x 4 disques/RAIDZ2
# - OU 24 rotatifs/JBOD -> POOL 'ROT', 6 x 4 disques/RAIDZ2
# - OS installé sur cartes SD interne -> montage '/var' sur dataset ZFS

########################################################################
echo "* Configuration APT"

cp /etc/apt/sources.list /etc/apt/sources.list.orig

release=$(lsb_release -c |awk '{print $2}')

cat<<EOF>/etc/apt/sources.list
deb http://ubuntu.univ-reims.fr/ubuntu/ ${release} main restricted universe multiverse
# deb-src http://ubuntu.univ-reims.fr/ubuntu/ ${release} main restricted universe multiverse

deb http://ubuntu.univ-reims.fr/ubuntu/ ${release}-updates main restricted universe multiverse
# deb-src http://ubuntu.univ-reims.fr/ubuntu/ ${release}-updates main restricted universe multiverse

deb http://ubuntu.univ-reims.fr/ubuntu/ ${release}-backports main restricted universe multiverse
# deb-src http://ubuntu.univ-reims.fr/ubuntu/ ${release}-backports main restricted universe multiverse

deb http://security.ubuntu.com/ubuntu ${release}-security main restricted universe multiverse
# deb-src http://security.ubuntu.com/ubuntu ${release}-security main restricted universe multiverse
EOF

apt-get update

echo

########################################################################
echo "* Suppression / ajout / mise à jour de paquets"

apt-get -y remove --purge mdadm open-iscsi
apt-get -y remove --purge lxd lxd-client lxcfs lxc-common liblxc1
apt-get -y autoremove --purge
rm -rf /var/lib/lxd/
apt-get -y upgrade
apt-get -y upgrade linux-generic
DEBIAN_FRONTEND=noninteractive apt-get -y install postfix
postconf -e relayhost=smtp.univ-reims.fr
service postfix restart
apt-get -y install zfsutils-linux joe htop arping mbuffer liblz4-tool smartmontools s-nail
apt-get -y install ifupdown ifenslave
apt-get clean
echo

########################################################################
echo "* Environnement Shell"

cat<<EOF>/root/.bash_aliases
alias ll='ls -lF'

alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
fi

EOF

echo

########################################################################
echo "* Création des pools ZFS"

devs=$(ls /dev/disk/by-id/ |grep '^ata-INTEL_SSD')
zpool create -f -o ashift=12 -O atime=off -O compression=lz4 -O normalization=formD -O mountpoint=none SSD raidz ${devs}

ndevs=$(ls -1 /dev/disk/by-id/ |grep "^scsi\-" |grep -v "\-part[0-9]" |wc -l)

case ${ndevs} in

 5) # Chaumont (5 rotatifs)
devs=$(ls /dev/disk/by-id/ |grep '^scsi\-' |grep -v "\-part[0-9]")
devs=(${devs})
zpool create -f -o ashift=12 -O atime=off -O compression=lz4 -O normalization=formD -O mountpoint=none ROT\
 raidz2 ${devs[0]} ${devs[1]} ${devs[2]} ${devs[3]} ${devs[4]}
 ;;

 12) # Chalons, Charleville, Troyes (1 JBOD: 12 rotatifs)
devs=$(ls /dev/disk/by-id/ |grep '^scsi\-'|grep -v "\-part[0-9]")
devs=(${devs})
zpool create -f -o ashift=12 -O atime=off -O compression=lz4 -O normalization=formD -O mountpoint=none ROT\
 raidz2 ${devs[0]} ${devs[1]} ${devs[2]} ${devs[3]}\
 raidz2 ${devs[4]} ${devs[5]} ${devs[6]} ${devs[7]}\
 raidz2 ${devs[8]} ${devs[9]} ${devs[10]} ${devs[11]}
 ;;

 24) # Reims (2 JBODs: 2x12 rotatifs)
devs=$(ls /dev/disk/by-id/ |grep '^scsi\-'|grep -v "\-part[0-9]")
devs=(${devs})
zpool create -f -o ashift=12 -O atime=off -O compression=lz4 -O normalization=formD -O mountpoint=none ROT\
 raidz2 ${devs[0]} ${devs[1]} ${devs[2]} ${devs[3]}\
 raidz2 ${devs[4]} ${devs[5]} ${devs[6]} ${devs[7]}\
 raidz2 ${devs[8]} ${devs[9]} ${devs[10]} ${devs[11]}
 raidz2 ${devs[12]} ${devs[13]} ${devs[14]} ${devs[15]}\
 raidz2 ${devs[16]} ${devs[17]} ${devs[18]} ${devs[19]}\
 raidz2 ${devs[20]} ${devs[21]} ${devs[22]} ${devs[23]}
 ;;

 *)
echo "Pas de disques rotatifs !"
exit
 ;;

esac

echo

########################################################################
echo "* Création des sous-volumes"

for p in SSD ROT; do for v in LOCAL SHARED ; do zfs create $p/$v ; done ; done

echo

########################################################################
echo "* Création et configuration du volume pour la swap"

zfs create -V 4G -b $(getconf PAGESIZE) -o compression=zle\
 -o logbias=throughput -o sync=always\
 -o primarycache=metadata -o secondarycache=none\
 -o com.sun:auto-snapshot=false SSD/LOCAL/swap

cat<<EOF>>/etc/fstab

/dev/zvol/SSD/LOCAL/swap none swap defaults,nofail,x-systemd.requires=zfs-mount.service 0 0
EOF

mkswap -L SWAP -f /dev/zvol/SSD/LOCAL/swap
swapon -L SWAP

echo

########################################################################
echo "* Création et configuration du volume pour /var/"

zfs create -o mountpoint=legacy ROT/LOCAL/var

cat<<EOF>>/etc/fstab

ROT/LOCAL/var /var zfs defaults,nofail,x-systemd.requires=zfs-mount.service 0 0

EOF

echo

########################################################################
echo "* Désactivation '/swapfile'"

sed -i 's/^\/swapfile/#\/swapfile/g' /etc/fstab

echo

########################################################################
echo "* Arrêter les services (fichiers ouverts sur /var)"

for s in dbus rsyslog cron atd postfix ; do service $s stop ; done

echo

########################################################################
echo "* Déplacer le contenu de /var/"

mv /var /var.orig
mkdir /var
mount /var
rsync -a /var.orig/ /var/

echo

########################################################################
echo "* Création des volumes pour libvirt"

zfs create SSD/SHARED/libvirt
zfs create ROT/SHARED/libvirt

echo

########################################################################
echo "* Création des volumes système de libvirt"

zfs create -o mountpoint=legacy ROT/SHARED/libvirt/etc
mkdir /etc/libvirt
mount -t zfs ROT/SHARED/libvirt/etc /etc/libvirt -o defaults,noatime,nodiratime

zfs create -o mountpoint=legacy ROT/SHARED/libvirt/var_lib
mkdir /var/lib/libvirt
mount -t zfs ROT/SHARED/libvirt/var_lib /var/lib/libvirt -o defaults,noatime,nodiratime

echo

########################################################################
echo "* Création du volume partagé HVM (données à transférer avec les snapshots)"

zfs create -o mountpoint=legacy SSD/SHARED/hvm
mkdir -p /var/lib/hvm/

echo

########################################################################
echo "* Installer les paquets de virtualisation"

apt-get -y install libvirt-bin virtinst qemu-kvm ovmf virt-top
apt-get clean

echo

########################################################################
echo "* Démarrage libvirt"

service virtlockd start
service virtlogd start
service libvirtd start

echo

########################################################################
echo "* Création volumes des pools de stockage"

zfs create -o mountpoint=/LIBVIRT/ROT ROT/SHARED/libvirt/images
zfs create -o mountpoint=/LIBVIRT/SSD SSD/SHARED/libvirt/images
zfs create -o mountpoint=/LIBVIRT/ISO ROT/SHARED/libvirt/iso

virsh pool-define-as ROT --type dir --target /LIBVIRT/ROT
virsh pool-define-as SSD --type dir --target /LIBVIRT/SSD
virsh pool-define-as ISO --type dir --target /LIBVIRT/ISO

virsh pool-start ROT
virsh pool-start SSD
virsh pool-start ISO

virsh pool-autostart ROT
virsh pool-autostart SSD
virsh pool-autostart ISO

echo

########################################################################
echo "* Limiter la quantité de RAM utilisée par ARC/ZFS à 16 Go"

cat<<EOF>/etc/modprobe.d/zfs.conf
options zfs zfs_arc_max=$((16 * 1024 * 1024 * 1024))
EOF

echo

########################################################################
echo "* Neutraliser le démarrage automatique de libvirt"

systemctl disable libvirt-guests
systemctl disable libvirt-bin
systemctl disable libvirtd

echo

########################################################################
echo "* Neutraliser l'utilisation du démon log qemu/libvirt"

cat<<EOF >> /etc/libvirt/qemu.conf
stdio_handler = "file"
EOF

echo

########################################################################
echo "* Désactivation IPv6 / hôte"

grep -q "disable_ipv6=1" /etc/sysctl.conf
if [ $? -ne 0 ] ; then
cat<<EOF>>/etc/sysctl.conf

net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
fi

echo

########################################################################
echo "* Mise en place configuration réseau pour libvirt / ifupdown"

cp interfaces /etc/network/interfaces
cp bond1 /etc/network/interfaces.d/

echo

########################################################################
cat<<EOF
** Préparation terminée ! **

- Redémarrer le serveur
- Lancer le script d'installation 'hvm/install.sh'
- Configurer le fichier de configuration '/usr/local/hvm/etc/local.conf'

EOF
