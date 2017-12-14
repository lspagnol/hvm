#!/bin/bash

########################################################################
# Fonctions HVM => script de contrôle de l'hyperviseur
########################################################################

function hvm_status { # Etat complet de l'hyperviseur
#- Pas d'argument
#-

_hv_status -v
_hv_sharedIP_status -v
_kvms_status -v

}

########################################################################

function hvm_backup { # Cycle de sauvegarde complet des VMs (backup + snap ZFS + sync ZFS)
#- Pas d'argument
#- 

local t0 t1 t2 t3
local last_snap_loc last_snap_rem

WARNING "DOT NOT use virt-manager while operation is in progress !!"
echo

# Timestamp début
t0=$(date +%s)

# Verrouiller hôte local et distant
LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

# Snapshot local le plus récent
last_snap_loc=$(_zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -1)
echo -n "* Last local snapshot is '${last_snap_loc} - "
date -d @${last_snap_loc} +"%d/%m/%Y %T (%a)'"
echo

# Timestamp suspension VMs
t1=$(date +%s)

echo "* Disable VMs autostart"
_kvms_disable_libvirt_autostart
echo

echo "* Backup VMs state"
_kvms_backup ${t1}
echo

echo "* Create recursive ZFS snapshots"
_zfs_snap_create ${t1}
echo

echo -n "* Last local snapshot is '${t1} - "
date -d @${t1} +"%d/%m/%Y %T (%a)'"
echo

echo "* Restore VMs state"
_kvms_restore
echo

# Timestamp reprise VMs
t2=$(date +%s)

LOCK_REMOTE || ABORT "unable to acquire lock on remote host"

echo "* Check Hypervisor state on remote host"
ssh ${node_rem} "hvm func _hv_status"
if [ $? -eq 0 ] ; then
	UNLOCK_REMOTE
	ABORT "not allowed while libvirt is running on remote host"
fi
echo

echo "* Check VMs state on remote host"
ssh ${node_rem} "hvm func _kvms_status"
if [ $? -eq 0 ] ; then
	UNLOCK_REMOTE
	ABORT "some VMs are running on remote host"
fi
echo

# Snapshot distant le plus récent
last_snap_rem=$(ssh ${node_rem} "hvm func _zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -1")
echo -n "* Last remote snapshot is '${last_snap_rem} - "
date -d @${last_snap_rem} +"%d/%m/%Y %T (%a)'"
echo

# Vérifier l'état des snapshots entre les deux hôtes
echo "* Compare snapshots '${last_snap_rem}' between hosts"
_zfs_snap_compare ${last_snap_rem}
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${last_snap_rem}' are not available on local host"
fi
echo

echo "* Umount storage on remote host"
ssh ${node_rem} "hvm func _zfs_umount"
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "unable to umount remote storage"
fi
echo

echo "* Rollback storage on remote host"
ssh ${node_rem} "hvm func _zfs_snap_rollback ${last_snap_rem}"
echo

echo "* Sync ZFS snapshots on remote host"
_zfs_snap_sync
echo

# Vérifier si les snapshots associés sont identiques sur les deux machines
echo "* Compare snapshots '${t1}' between hosts"
_zfs_snap_compare ${t1}
if [ $? -ne 0 ] ; then
	WARNING "zfs snapshots '${t1}' are not available on remote host"
fi
echo

# Déverrouiller hôte local et distant
UNLOCK_REMOTE
UNLOCK

# Timestamp fin
t3=$(date +%s)

echo "* Backup done in $(( ${t3} - ${t0})) seconds"
echo "* VMs unavailable for $(( ${t2} - ${t1} )) seconds"
echo

}

########################################################################

function hvm_constraint_show { # Afficher la contrainte d'hébergement des VMs
#- Pas d'argument
#-

local c

_hv_status || ABORT "not allowed while libvirt is stopped"

if [ -f ${HVM_TMP_DIR}/constraint ] ; then
	c=$(<${HVM_TMP_DIR}/constraint)
	c=(${c})
	echo "${c[0]} $(date -d @${c[1]} +%d/%m/%Y) $(date -d @${c[2]} +%d/%m/%Y)"
fi

return 0

}

function hvm_constraint_set { # Paramétrer la contrainte d'hébergement des VMs
#- Arg 1 -> nom de l'hôte
#- Arg 2 -> today | tomorow | date début (J/M/AAAA)
#- Arg 3 -> date fin optionnelle ((J/M/AAAA)
#-

local d0 d1

_hv_status || ABORT "not allowed while libvirt is stopped"

echo " ${HVM_HOSTS[@]} " |grep -q " ${1} "
[ $? -eq 0 ] || ABORT "hostname must be '${node_loc}' or '${node_rem}'"

case ${2} in
	today)
		d0=$(date -d today "+%d/%m/%Y")
	;;
	tomorrow)
		d0=$(date -d tomorrow "+%d/%m/%Y")
	;;
	*)
		d0=${2}
	;;
esac

d0=$(dateconv ${d0})
d0=$(date -d ${d0} "+%s")

if [ -z "${3}" ] ; then
	# Pas de date de fin -> prendre date de début
	d1=${d0}
else
	# Convertir la date passée en argument
	d1=$(dateconv ${3})
	d1=$(date -d ${d1} "+%s")
fi
# Ajouter 24h - 1 seconde
d1=$(( ${d1} + 86399 ))

# Enregister la contraine
echo "${1} ${d0} ${d1}" > ${HVM_TMP_DIR}/constraint

hvm_constraint_show

return 0

}

function hvm_constraint_unset { # Annuler la contrainte d'hébergement des VMs
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

if [ -f ${HVM_TMP_DIR}/constraint ] ; then
	rm ${HVM_TMP_DIR}/constraint
fi

hvm_constraint_show

return 0

}

########################################################################

function hvm_migrate_unsecure { # Migration "rapide" des VMs
#- Pas d'argument
#-

local t0 t1
local vms vm
local last_snap_loc last_snap_rem

WARNING "DOT NOT use virt-manager while operation is in progress !!"
echo

# Timestamp début
t0=$(date +%s)

# Verrouiller hôte local et distant
LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

[ "$(_kvms_list_snapshots)" = "" ] || ABORT "not allowed while VM has libvirt snapshot, please use 'hvm migrate secure'"
[ "$(_kvms_list_freezed)" = "" ] || ABORT "not allowed while VM is freezed, please use 'hvm migrate secure'"

LOCK_REMOTE || ABORT "unable to acquire lock on remote host"

echo "* Check Hypervisor state on remote host"
ssh ${node_rem} "hvm func _hv_status"
if [ $? -eq 0 ] ; then
	UNLOCK_REMOTE
	ABORT "not allowed while libvirt is running on remote host"
fi
echo

echo "* Check VMs state on remote host"
ssh ${node_rem} "hvm func _kvms_status"
if [ $? -eq 0 ] ; then
	UNLOCK_REMOTE
	ABORT "some VMs are running on remote host"
fi
echo

# Snapshot local le plus récent
last_snap_loc=$(_zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -1)
echo -n "* Last local snapshot is '${last_snap_loc} - "
date -d @${last_snap_loc} +"%d/%m/%Y %T (%a)'"
echo

# Snapshot distant le plus récent
last_snap_rem=$(ssh ${node_rem} "hvm func _zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -1")
echo -n "* Last remote snapshot is '${last_snap_rem} - "
date -d @${last_snap_rem} +"%d/%m/%Y %T (%a)'"
echo

# Vérifier l'état des snapshots entre les deux hôtes
echo "* Compare snapshots '${last_snap_loc}' between hosts"
_zfs_snap_compare ${last_snap_loc}
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${last_snap_loc}' are not available on remote host"
fi
echo

echo "* Umount storage on remote host"
ssh ${node_rem} "hvm func _zfs_umount"
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "unable to umount remote storage"
fi
echo

echo "* Rollback storage on remote host"
ssh ${node_rem} "hvm func _zfs_snap_rollback ${last_snap_loc}"
echo

echo "* Create recursive ZFS snapshots"
_zfs_snap_create ${t0}
echo

echo -n "* Last local snapshot is '${t0} - "
date -d @${t0} +"%d/%m/%Y %T (%a)'"
echo

echo "* Sync ZFS snapshots on remote host"
_zfs_snap_sync
echo

# Vérifier si les snapshots associés sont identiques sur les deux machines
echo "* Compare snapshots '${t0}' between hosts"
_zfs_snap_compare ${t0}
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${t0}' are not available on remote host"
fi
echo

echo "* Disable VMs autostart on local host"
_kvms_disable_libvirt_autostart
echo

echo "* Disable VMs autostart on remote host"
ssh ${node_rem} "hvm func _zfs_mount ; rm ${KVM_AUTOSTART_DIR}/*.xml 2>/dev/null ; hvm func _zfs_umount"
echo

echo "* Start libvirt on remote host"
ssh ${node_rem} "hvm func _hv_start"
echo

echo "* Live migrate VMs on remote host"
vms="$(_kvms_list_running) $(_kvms_list_freezed)"
for vm in ${vms} ; do
	echo "- '${vm}':"
	virsh migrate ${vm} --verbose --live --desturi qemu+ssh://root@${node_rem}/system
	ssh ${node_rem} "rm ${KVM_BACKUP_DIR}/${vm} 2>/dev/null"
	sleep 1
done
echo

echo "* Disable shared IP on local host"
_hv_sharedIP_disable
echo

echo "* Stop libvirt on local host"
_hv_stop
echo

echo "* Enable shared IP on remote host"
ssh ${node_rem} "hvm func _hv_sharedIP_enable"
echo

# Déverrouiller hôte local et distant
UNLOCK_REMOTE
UNLOCK

# Timestamp fin
t1=$(date +%s)

echo "* Migrate done in $(( ${t1} - ${t0})) seconds"
echo

}

########################################################################

function hvm_migrate_secure { # Migration "sécurisée" des VMs
#- Pas d'argument
#-

local t0 t1 t2 t3 t4
local last_snap_loc last_snap_rem

WARNING "DOT NOT use virt-manager while operation is in progress !!"
echo

# Timestamp début
t0=$(date +%s)

# Verrouiller hôte local et distant
LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"
LOCK_REMOTE || ABORT "unable to acquire lock on remote host"

echo "* Check Hypervisor state on remote host"
ssh ${node_rem} "hvm func _hv_status"
if [ $? -eq 0 ] ; then
	UNLOCK_REMOTE
	ABORT "not allowed while libvirt is running on remote host"
fi
echo

echo "* Check VMs state on remote host"
ssh ${node_rem} "hvm func _kvms_status"
if [ $? -eq 0 ] ; then
	UNLOCK_REMOTE
	ABORT "some VMs are running on remote host"
fi
echo

# Snapshot local le plus récent
last_snap_loc=$(_zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -1)
echo -n "* Last local snapshot is '${last_snap_loc} - "
date -d @${last_snap_loc} +"%d/%m/%Y %T (%a)'"
echo

# Snapshot distant le plus récent
last_snap_rem=$(ssh ${node_rem} "hvm func _zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -1")
echo -n "* Last remote snapshot is '${last_snap_rem} - "
date -d @${last_snap_rem} +"%d/%m/%Y %T (%a)'"
echo

# Vérifier l'état des snapshots entre les deux hôtes
echo "* Compare snapshots '${last_snap_loc}' between hosts"
_zfs_snap_compare ${last_snap_loc}
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${last_snap_loc}' are not available on remote host"
fi
echo

echo "* Umount storage on remote host"
ssh ${node_rem} "hvm func _zfs_umount"
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "unable to umount remote storage"
fi
echo

echo "* Rollback storage on remote host"
ssh ${node_rem} "hvm func _zfs_snap_rollback ${last_snap_loc}"
echo

# 1ère synchro ZFS (à chaud)

echo "* Create recursive ZFS snapshots (stage 1/3)"
_zfs_snap_create ${t0}
echo

echo -n "* Last local snapshot is '${t0} - "
date -d @${t0} +"%d/%m/%Y %T (%a)'"
echo

echo "* Sync ZFS snapshots on remote host (stage 1/3)"
_zfs_snap_sync
echo

# Vérifier si les snapshots associés sont identiques sur les deux machines
echo "* Compare snapshots '${t0}' between hosts"
_zfs_snap_compare ${t0}
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${t0}' are not available on remote host"
fi
echo

t1=$(date +%s)

# 2ème synchro ZFS (à chaud)

echo "* Create recursive ZFS snapshots (stage 2/3)"
_zfs_snap_create ${t1}
echo

echo -n "* Last local snapshot is '${t1} - "
date -d @${t1} +"%d/%m/%Y %T (%a)'"
echo

echo "* Sync ZFS snapshots on remote host (stage 2/3)"
_zfs_snap_sync
echo

# Vérifier si les snapshots associés sont identiques sur les deux machines
echo "* Compare snapshots '${t1}' between hosts"
_zfs_snap_compare ${t1}
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${t1}' are not available on remote host"
fi
echo

echo "* Disable VMs autostart on local host"
_kvms_disable_libvirt_autostart
echo

# Timestamp suspension VMs
t2=$(date +%s)

echo "* Backup VMs state"
_kvms_backup ${t2}
echo

# 3ème synchro ZFS (à froid)

echo "* Create recursive ZFS snapshots (stage 3/3)"
_zfs_snap_create ${t2}
echo

echo -n "* Last local snapshot is '${t2} - "
date -d @${t2} +"%d/%m/%Y %T (%a)'"
echo

echo "* Sync ZFS snapshots on remote host (stage 3/3)"
_zfs_snap_sync
echo

# Vérifier si les snapshots associés sont identiques sur les deux machines
echo "* Compare snapshots '${t2}' between hosts"
_zfs_snap_compare ${t2}
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${t2}' are not available on remote host"
fi
echo

echo "* Disable shared IP on local host"
_hv_sharedIP_disable
echo

echo "* Stop libvirt on local host"
_hv_stop
echo

echo "* Start libvirt on remote host"
ssh ${node_rem} "hvm func _hv_start"
echo

echo "* Restore VMs state on remote host"
ssh ${node_rem} "hvm func _kvms_restore"
echo

# Timestamp reprise VMs
t3=$(date +%s)

echo "* Enable shared IP on remote host"
ssh ${node_rem} "hvm func _hv_sharedIP_enable"
echo

# Déverrouiller hôte local et distant
UNLOCK_REMOTE
UNLOCK

# Timestamp fin
t4=$(date +%s)

echo "* Migrate done in $(( ${t4} - ${t0})) seconds"
echo "* VMs unavailable for $(( ${t3} - ${t2} )) seconds"
echo

}

########################################################################

function hvm_zfs_mount { # Monter les volumes ZFS de l'hyperviseur
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"

_zfs_mount

UNLOCK

}

########################################################################

function hvm_zfs_umount { # Démonter les volumes ZFS de l'hyperviseur
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status && ABORT "not allowed while libvirt is running"
_kvms_status && ABORT "not allowed while VMs are running"

_zfs_umount

UNLOCK

}

########################################################################

function hvm_hv_status { # Etat de l'hyperviseur (libvirt)
#- Pas d'argument
#-

_hv_status -v

}

########################################################################

function hvm_hv_start { # Démarrer l'hyperviseur
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status && ABORT "libvirt is already running"

_hv_sharedIP_enable
_hv_start

UNLOCK

}

########################################################################

function hvm_hv_stop { # Arrêter l'hyperviseur
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "libvirt is already stopped"
_kvms_status && ABORT "not allowed while VMs are running"

# Désactiver le démarrage automatique des VMs
_kvms_disable_libvirt_autostart

_hv_stop
_hv_sharedIP_disable

UNLOCK

}

########################################################################

function hvm_hv_sharedIP_enable { # Activer l'adresse IP partagée
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"

_hv_sharedIP_enable

UNLOCK

}

########################################################################

function hvm_hv_sharedIP_disable { # Désactiver l'adresse IP partagée
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"

_hv_sharedIP_disable

UNLOCK

}

########################################################################

function hvm_vm_status { # Etat d'une VM
#- Arg 1 -> nom VM
#-

_hv_status || ABORT "not allowed while libvirt is stopped"
[ -z "${1}" ] && ABORT "VM name is required"

echo -n "KVM '${1}' is "
_kvm_is_running ${1}
if [ $? -eq 0 ] ; then
	echo "running"
else
	echo "stopped"
fi

return 0

}

########################################################################

function hvm_vm_start { # Démarrer une VM
#- Arg 1 -> nom VM
#-

_hv_status || ABORT "not allowed while libvirt is stopped"
[ -z "${1}" ] && ABORT "VM name is required"
LOCK || ABORT "unable to acquire lock"

_kvm_is_running ${1}
if [ $? -ne 0 ] ; then
	_kvm_start ${1}
else
	ABORT "not allowed while VM is running"
fi

UNLOCK

return 0

}

########################################################################

function hvm_vm_freeze { # Figer une VMs
#- Arg 1 -> nom VM
#-

_hv_status || ABORT "not allowed while libvirt is stopped"
[ -z "${1}" ] && ABORT "VM name is required"
LOCK || ABORT "unable to acquire lock"

_kvm_is_running ${1}
if [ $? -eq 0 ] ; then
	_kvm_freeze ${1}
else
	ABORT "not allowed while VM is stopped"
fi

UNLOCK

return 0

}

########################################################################

function hvm_vm_unfreeze { # Reprise d'une VM figée
#- Arg 1 -> nom VM
#-

_hv_status || ABORT "not allowed while libvirt is stopped"
[ -z "${1}" ] && ABORT "VM name is required"
LOCK || ABORT "unable to acquire lock"

_kvm_is_freezed ${1}
if [ $? -eq 0 ] ; then
	_kvm_unfreeze ${1}
fi

UNLOCK

return 0

}

########################################################################

function hvm_vm_shutdown { # Arrêt d'une VM
#- Arg 1 -> nom VM
#-

_hv_status || ABORT "not allowed while libvirt is stopped"
[ -z "${1}" ] && ABORT "VM name is required"
LOCK || ABORT "unable to acquire lock"

[ -z "${1}" ] && ABORT "VM name is required"

_kvm_is_running ${1}
if [ $? -eq 0 ] ; then
	_kvm_shutdown ${1}
else
	ABORT "not allowed while VM is stopped"
fi

UNLOCK

return 0

}

########################################################################

function hvm_vm_poweroff { # Couper une VM
#- Arg 1 -> nom VM
#-

_hv_status || ABORT "not allowed while libvirt is stopped"
[ -z "${1}" ] && ABORT "VM name is required"
LOCK || ABORT "unable to acquire lock"

_kvm_is_running ${1}
if [ $? -eq 0 ] ; then
	_kvm_poweroff ${1}
else
	ABORT "not allowed while VM is stopped"
fi

UNLOCK

return 0

}

########################################################################

function hvm_vm_backup { # Sauvegarder l'état d'une VM
#- Arg 1 -> nom VM
#-

_hv_status || ABORT "not allowed while libvirt is stopped"
[ -z "${1}" ] && ABORT "VM name is required"
LOCK || ABORT "unable to acquire lock"

[ -z "${1}" ] && ABORT "KVM name is required"

_kvm_is_running ${1} || _kvm_is_freezed ${1}
if [ $? -eq 0 ] ; then
	_kvm_backup ${1} $(date +%s)
else
	ABORT "not allowed while VM is stopped"
fi

UNLOCK

return 0

}

########################################################################

function hvm_vm_restore { # Restaurer une VM sauvegardée
#- Arg 1 -> nom VM
#-

_hv_status || ABORT "not allowed while libvirt is stopped"
[ -z "${1}" ] && ABORT "VM name is required"
LOCK || ABORT "unable to acquire lock"

[ -z "${1}" ] && ABORT "KVM name is required"

_kvm_is_running ${1}
if [ $? -ne 0 ] ; then
	_kvm_restore ${1}
else
	ABORT "not allowed while VM is running"
fi

UNLOCK

return 0

}

########################################################################

function hvm_vms_status { # Etat des VMs
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_status -v

return 0

}

########################################################################

function hvm_vms_start {
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_start

UNLOCK

return 0

}

########################################################################

function hvm_vms_freeze { # Figer toutes les VMs
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_freeze

UNLOCK

return 0

}

########################################################################

function hvm_vms_unfreeze { # Reprise des VMs figées
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_unfreeze

UNLOCK

return 0

}


########################################################################

function hvm_vms_shutdown { # Arrêter les VMs
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_shutdown

UNLOCK

return 0

}

########################################################################

function hvm_vms_poweroff { # Couper les VMs
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_poweroff

UNLOCK

return 0

}

########################################################################

function hvm_vms_backup { # Sauvegarder l'état des VMs
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_backup $(date +%s)

UNLOCK

return 0

}

########################################################################

function hvm_vms_restore { # Restaurer l'état des VMs sauvegardées
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_restore

UNLOCK

return 0

}

########################################################################

function hvm_vms_list_all { # Liste des toutes les VMs
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_list_all

return 0

}

########################################################################

function hvm_vms_list_running { # Liste des VMs en fonctionnement
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_list_running

return 0

}

########################################################################

function hvm_vms_list_freezed { # Liste des VMs figées
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_list_freezed

return 0

}

########################################################################

function hvm_vms_list_stopped { # Liste des VMs arrêtées
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_list_stopped

return 0

}

########################################################################

function hvm_vms_list_backups { # Liste des VMs sauvegardés ou avec snapshot
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_list_backups

return 0

}

########################################################################

function hvm_vms_list_autostart { # Liste des VMs avec démarrage automatique
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_list_autostart

return 0

}

########################################################################

function hvm_vms_list_prio { # Liste de priorité des VMs
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

_kvms_list_prio |sort -n

return 0

}

########################################################################

function hvm_zfs_snap_list_all { # Liste de tous les snapshots ZFS
#- Pas d'argument
#-

_zfs_snap_list_all

return 0

}

########################################################################

function hvm_zfs_snap_list_dates { # Liste des timestamps de snapshots ZFS avec date
#- Pas d'argument
#-

_zfs_snap_list_dates

return 0

}

########################################################################

function hvm_zfs_snap_list_lasts { # Liste des derniers snapshots ZFS
#- Pas d'argument
#-

_zfs_snap_list_lasts

return 0

}

########################################################################

function hvm_zfs_snap_create { # Créer un snapshot ZFS
#- Pas d'argument
#-

LOCK || ABORT "unable to acquire lock"

_zfs_snap_create $(date +%s)

UNLOCK

return 0

}

########################################################################

function hvm_zfs_snap_sync { # Synchroniser les snapshots ZFS sur l'hôte distant
#- Pas d'argument
#-

local last_snap_loc last_snap_rem

# Timestamp début
t0=$(date +%s)

# Verrouiller hôte local et distant
LOCK || ABORT "unable to acquire lock"
_hv_status || ABORT "not allowed while libvirt is stopped"
LOCK_REMOTE || ABORT "unable to acquire lock on remote host"

echo "* Check Hypervisor state on remote host"
ssh ${node_rem} "hvm func _hv_status"
if [ $? -eq 0 ] ; then
	UNLOCK_REMOTE
	ABORT "not allowed while libvirt is running on remote host"
fi
echo

echo "* Check VMs state on remote host"
ssh ${node_rem} "hvm func _kvms_status"
if [ $? -eq 0 ] ; then
	UNLOCK_REMOTE
	ABORT "some VMs are running on remote host"
fi
echo

# Snapshot local le plus récent
last_snap_loc=$(_zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -1)
echo -n "* Last local snapshot is '${last_snap_loc} - "
date -d @${last_snap_loc} +"%d/%m/%Y %T (%a)'"
echo

# Snapshot distant le plus récent
last_snap_rem=$(ssh ${node_rem} "hvm func _zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -1")
echo -n "* Last remote snapshot is '${last_snap_rem} - "
date -d @${last_snap_rem} +"%d/%m/%Y %T (%a)'"
echo

if [ "${last_snap_loc}" = "${last_snap_rem}" ] ; then
	# Le snapshot local a déjà été synchronisé sur l'hôte distant
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${last_snap_loc}' are already available on remote host"
fi

# Vérifier l'état des snapshots entre les deux hôtes
echo "* Compare snapshots '${last_snap_rem}' between hosts"
_zfs_snap_compare ${last_snap_rem}
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "zfs snapshots '${last_snap_rem}' are not available on local host"
fi
echo

echo "* Umount storage on remote host"
ssh ${node_rem} "hvm func _zfs_umount"
if [ $? -ne 0 ] ; then
	UNLOCK_REMOTE
	ABORT "unable to umount remote storage"
fi
echo

echo "* Rollback storage on remote host"
ssh ${node_rem} "hvm func _zfs_snap_rollback ${last_snap_rem}"
echo

echo "* Sync ZFS snapshots on remote host"
_zfs_snap_sync
echo

# Vérifier si les snapshots associés sont identiques sur les deux machines
echo "* Compare snapshots '${last_snap_loc}' between hosts"
_zfs_snap_compare ${last_snap_loc}
if [ $? -ne 0 ] ; then
	WARNING "zfs snapshots '${last_snap_loc}' are not available on remote host"
fi
echo

# Déverrouiller hôte local et distant
UNLOCK_REMOTE
UNLOCK

# Timestamp fin
t1=$(date +%s)

echo "* ZFS snapshots sync done in $(( ${t1} - ${t0})) seconds"
echo

UNLOCK

return 0

}

########################################################################

function hvm_zfs_snap_createsync { # Créer et synchroniser un snapshot ZFS
#- Pas d'argument
#-

_hv_status || ABORT "not allowed while libvirt is stopped"

hvm_zfs_snap_create
hvm_zfs_snap_sync

return 0

}

########################################################################

function hvm_zfs_snap_rollback { # Retour arrière sur un snapshot ZFS
#- Arg 1 -> timestamp du snapshot
#-

LOCK || ABORT "unable to acquire lock"

_zfs_snap_rollback ${1}

UNLOCK

return 0

}

########################################################################

function hvm_zfs_snap_purge { # Purge des snapshots ZFS
#- Arg 1 -> vide: affiche seulement les snapshots à supprimer
#-          -e  : supprime les snapshots
#-

LOCK || ABORT "unable to acquire lock"

_zfs_snap_purge ${1}

UNLOCK

return 0

}
