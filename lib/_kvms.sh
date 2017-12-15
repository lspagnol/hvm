#!/bin/bash

########################################################################
# Fonctions KVMS (contrôle groupé des VMs)
########################################################################

function _kvms_status { # Déterminer / afficher si VMs actives / pas actives
#- si '-v' passé en argument -> afficher état
#- return '0' si actif, sinon return '1'

[ "${1}" = "-v" ] && echo -n "VMs are "

ps ax |grep -v grep |grep -q " qemu-system-"

if [ $? -eq 0 ] ; then
	[ "${1}" = "-v" ] && echo "running"
	return 0
else
	[ "${1}" = "-v" ] && echo "stopped"
	return 1
fi

}

########################################################################

function _kvms_list { # Afficher liste des VMs

virsh list --all --name |grep -v '^$'

return 0

}

function _kvms_list_all { # Afficher liste + état des VMs

virsh list --all |grep -v '^$'

return 0

}

function _kvms_list_running { # Afficher liste VMs actives

virsh list --name --state-running |grep -v '^$'

return 0

}

function _kvms_list_freezed { # Afficher liste VMs figées

virsh list --name --state-paused |grep -v '^$'

return 0

}

function _kvms_list_stopped { # Afficher liste VMs arrêtées

virsh list --name --state-shutoff |grep -v '^$'

return 0

}

function _kvms_list_backups { # Afficher liste VMs avec sauvegarde

ls -1 ${KVM_BACKUP_DIR} 2>/dev/null |sed 's/\.save//'

return 0

}

function _kvms_list_snapshots { # Afficher liste des VMs avec snapshot

local vms vm

vms=$(ls ${KVM_SNAPSHOT_DIR})
for vm in ${vms} ; do
	_kvm_has_snapshot ${vm}
	if [ $? -eq 0 ] ; then
		echo "${vm}"
	fi
done

return 0

}

function _kvms_list_autostart { # Afficher la liste des VMs avec démarrage automatique

local vms vm

vms=$(_kvms_list)

for vm in ${vms} ; do
	_kvm_has_autostart ${vm}
	if [ $? -eq 0 ] ; then
		echo ${vm}
	fi
done

return 0

}

function _kvms_list_prio { # Afficher la priorité des VMs

local vms vm

vms=$(_kvms_list)

for vm in ${vms} ; do
	echo "$(_kvm_prio ${vm}) ${vm}"
done

return 0

}

########################################################################

function _kvms_freeze { # Figer les VMs

local vms vm

vms=$(_kvms_list_prio |sort -nr |awk '{print $2}')

for vm in ${vms} ; do

	_kvm_is_running ${vm}
	if [ $? -eq 0 ] ; then
		_kvm_freeze ${vm}
	fi

done

return 0

}

function _kvms_unfreeze { # Reprise des VMs figées

local vms vm

vms=$(_kvms_list_prio |sort -n |awk '{print $2}')

for vm in ${vms} ; do

	_kvm_is_freezed ${vm}
	if [ $? -eq 0 ] ; then
		_kvm_unfreeze ${vm}
	fi

done

return 0

}

########################################################################

function _kvms_backup { # Sauvegarder l'état des VMs
#- Arg 1 -> timestamp

local vms vm

if [ -z "${1}" ] ; then
	ERROR "timestamp is required"
	return 1
fi

vms=$(_kvms_list_prio |sort -nr |awk '{print $2}')

for vm in ${vms} ; do

	_kvm_is_running ${vm} || _kvm_is_freezed ${vm}
	if [ $? -eq 0 ] ; then
		_kvm_backup ${vm} ${1}
		sleep 1
	fi

done

return 0

}

function _kvms_restore { # Restaurer l'état des VMs

local vm vms

vms=$(_kvms_list_prio |sort -n |awk '{print $2}')

for vm in ${vms} ; do

	_kvm_is_running ${vm}
	if [ $? -ne 0 ] ; then
		_kvm_restore ${vm}
		sleep 1
	fi

done

return 0

}

########################################################################

function _kvms_start { # Démarrer les VMs dont le démarrage automatique est activé

local vm vms

vms=$(_kvms_list_prio |sort -n |awk '{print $2}')

for vm in ${vms} ; do

	_kvm_is_running ${vm}
	if [ $? -ne 0 ] ; then
		_kvm_has_autostart ${vm}
		if [ $? -eq 0 ] ; then
			_kvm_start ${vm}
			sleep 1
		fi
	fi

done

return 0

}

function _kvms_shutdown { # Arrêter les VMs

local vms vm

vms=$(_kvms_list_prio |sort -nr |awk '{print $2}')

for vm in ${vms} ; do

	_kvm_is_running ${vm} || _kvm_is_freezed ${vm}
	if [ $? -eq 0 ] ; then
		_kvm_shutdown ${vm}
		sleep 1
	fi

done

return 0

}

function _kvms_poweroff { # Forcer l'arrêt des VMs

local vms vm

vms=$(_kvms_list_prio |sort -nr |awk '{print $2}')

for vm in ${vms} ; do

	_kvm_is_running ${vm} || _kvm_is_freezed ${vm}
	if [ $? -eq 0 ] ; then
		_kvm_poweroff ${vm}
		sleep 1
	fi

done

return 0

}

########################################################################

function _kvms_disable_libvirt_autostart { # Désactiver le démarrage automatique natif des VMs/libvirt
#- Arg 1 => nom de la VM

local vms vm

vms=$(virsh list --autostart --name |grep -v '^$')

for vm in ${vms} ; do
	virsh autostart ${vm} --disable >/dev/null
done

return 0

}
