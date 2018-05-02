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
apt-get -y install zfsutils-linux joe htop arping mbuffer liblz4-tool smartmontools
apt-get -y install ifupdown ifenslave
apt-get -y install munin-node munin-plugins-extra munin-libvirt-plugins
apt-get clean

echo

########################################################################
echo "* Configuration Munin"

munin-node-configure
rm /etc/munin/plugins/if*_eno* 2>/dev/null
rm /etc/munin/plugins/if*_virbr* 2>/dev/null
rm /etc/munin/plugins/if*_vnet* 2>/dev/null
rm /etc/munin/plugins/smart_* 2>/dev/null
rm /etc/munin/plugins/postfix_* 2>/dev/null
rm /etc/munin/plugins/acpi 2>/dev/null
service munin-node stop ; service munin-node start

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

devs=$(ls /dev/disk/by-id/ |grep '^ata-INTEL_SSD' |grep -v "\-part[0-9]")
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
 raidz2 ${devs[8]} ${devs[9]} ${devs[10]} ${devs[11]}\
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
echo "* Limiter la quantité de RAM utilisée par ARC/ZFS à 32 Go"

cat<<EOF>/etc/modprobe.d/zfs.conf
options zfs zfs_arc_max=$((32 * 1024 * 1024 * 1024))
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
chattr +i /etc/network/interfaces
chattr +i /etc/network/interfaces.d/bond1
cp netcf.conf /etc/modprobe.d/netcf.conf

echo

########################################################################
echo "* Mise en place planification CRON"

sed "s/^MAILTO=kvm-admin@domain.tld/MAILTO=kvm-admin-$(hostname |cut -d- -f2)@univ-reims.fr/g" < hvm-cron > /etc/cron.d/hvm

echo

########################################################################
echo "* Verrouillage du dossier images par défaut de libvirt"

touch /var/lib/libvirt/images/DUMMY
chattr +i /var/lib/libvirt/images

echo

########################################################################
echo "* Installation du script 'zfs-tuning'"

wget -O zfs-tuning https://raw.githubusercontent.com/lspagnol/misc-scripts/master/zfs-tuning
chmod +x zfs-tuning
cp -f zfs-tuning /usr/local/sbin

echo

########################################################################
echo "* Installation outils iDrac Dell"

echo 'deb http://linux.dell.com/repo/community/ubuntu xenial openmanage' | sudo tee -a /etc/apt/sources.list.d/linux.dell.com.sources.list
#gpg --keyserver pool.sks-keyservers.net --recv-key 1285491434D8786F
#gpg -a --export 1285491434D8786F | sudo apt-key add -
cat<<EOF|apt-key add -
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
SNnmxzdpR6pYJGbEDdFyZFe5xHRWSlrC3WTbzg==
=WBHf
-----END PGP PUBLIC KEY BLOCK-----
EOF

apt-get update
apt-get -y install srvadmin-idracadm8

echo

########################################################################
cat<<EOF
** Préparation terminée ! **

- Lancer le script d'installation 'hvm/install.sh'
- Configurer le fichier '/usr/local/hvm/etc/local.conf'
- Configurer les VLANs via la commande 'hvm-interface-config'
- Redémarrer le serveur

EOF
