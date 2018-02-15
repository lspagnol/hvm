#!/bin/bash

########################################################################
# Fonctions KVM (contrôle individuel des VMs)
########################################################################

function _kvm_is_running { # Vérifier si la VM fonctionne
#- Arg 1 -> nom de la VM
#- Codes retour:
#- 0 -> la VM fonctionne
#- 1 -> la VM ne fonctionne pas

virsh domstate ${1} |grep -q '^running$'

if [ $? -eq 0 ] ; then
	return 0
else
	return 1
fi

}

function _kvm_is_freezed { # Vérifier si la VM est figée
#- Arg 1 -> nom de la VM
#- Codes retour:
#- 0 -> la VM fonctionne
#- 1 -> la VM ne fonctionne pas

virsh domstate ${1} |grep -q '^paused$'

if [ $? -eq 0 ] ; then
	return 0
else
	return 1
fi

}

function _kvm_has_backup { # Vérifier si la VM a une sauvegarde
#- Arg 1 -> nom de la VM
#- Codes retour:
#- 0 -> la VM a une sauvegarde
#- 1 -> la VM n'a pas de sauvegarde

if [ -f ${KVM_BACKUP_DIR}/${1}.backup ] ; then
	return 0
else
	return 1
fi

}

function _kvm_has_snapshot { # Vérifier si la VM a au moins un snapshot
#- Arg 1 => nom de la VM

ls ${KVM_SNAPSHOT_DIR}/${1}/*.xml 2>/dev/null >/dev/null

if [ $? -eq 0 ] ; then
	return 0
else
	return 1
fi

}

function _kvm_has_autostart { # Vérifier si la VM peut démarrer automatiquement
#- Arg 1 => nom de la VM
#- Codes retour:
#- 0 -> démarrage automatique activé
#- 1 -> démarrage automatique désactivé

virsh desc ${1} |egrep -q '^autostart=(yes|true|1)$'

if [ $? -eq 0 ] ; then
	return 0
else
	return 1
fi

}

function _kvm_has_autobackup { # Vérifier si la VM peut être sauvegardée automatiquement
#- Arg 1 => nom de la VM
#- Codes retour:
#- 0 -> sauvegarde automatique activée
#- 1 -> sauvegarde automatique désactivée

virsh desc ${1} |egrep -q '^autobackup=(yes|true|1)$'

if [ $? -eq 0 ] ; then
	return 0
else
	return 1
fi

}

function _kvm_has_vmgenid { # Vérifier si la fonctionnalité "VM generationID est activée" pour la VM
#- Arg 1 => nom de la VM
#- Codes retour:
#- 0 -> VM generationID activé
#- 1 -> VM generationID désactivé

virsh desc ${1} |egrep -q '^vmgenid=(yes|true|1)$'

if [ $? -eq 0 ] ; then
	return 0
else
	return 1
fi

}

function _kvm_prio { # Afficher la priorité de la VM
#- Arg 1 => nom de la VM
#- priorité de 1 à 99, correspond à l'ordre d'activation de la VM
#- utiliser la liste inversée pour la désactivation
#- pas de priorité => 99 par défaut

local p

p=$(virsh desc ${1} |egrep '^prio=[0-9]+$')
p=${p#*=}
p=${p:-99}

echo ${p}

return 0

}

########################################################################

function _kvm_backup { # Sauvegarder l'état de la VM
#- Arg 1 => nom de la VM

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

mkdir -p ${KVM_BACKUP_DIR}

_kvm_is_running ${1} || _kvm_is_freezed ${1}
if [ $? -eq 0 ] ; then

	virsh save ${1} ${KVM_BACKUP_DIR}/${1}.backup |grep -v '^$'
	if [ ${PIPESTATUS[0]} -ne 0 ] ; then
		ERROR "'virsh managedsave' has failed"
		return 1
	fi

	return 0

else

	ERROR "can't backup stopped VM '${1}'"
	return 1

fi

}

function _kvm_restore { # Restaurer l'état d'une VM
#- Arg 1 => nom de la VM

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

local snap

_kvm_is_running ${1} || _kvm_is_freezed ${1}
if [ $? -ne 0 ] ; then

	_kvm_has_backup ${1}
	if [ $? -eq 0 ] ; then

		virsh restore ${KVM_BACKUP_DIR}/${1}.backup |grep -v '^$'
		if [ ${PIPESTATUS[0]} -ne 0 ] ; then
			ERROR "'virsh start' has failed for VM '${1}'"
			rm ${KVM_BACKUP_DIR}/${1}.backup
			return 1
		fi

		rm ${KVM_BACKUP_DIR}/${1}.backup

		# Mise à l'heure de la VM
		_kvm_ga_timesync ${1}

		return 0

	else

		ERROR "VM '${1}' has no backup"
		return 1

	fi

else

	ERROR "can't restore already running or freezed VM '${1}'"
	return 1

fi

}

########################################################################

function _kvm_start { # Démarrer une VM
#- Arg 1 => nom de la VM

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

local snap

_kvm_is_running ${1}
if [ $? -ne 0 ] ; then

	_kvm_has_backup ${1}
	if [ $? -eq 0 ] ; then

		ERROR "VM '${1}' has HVM backup/snapshot"
		return 1

	else

		# Activer Qemu Guest Agent pour la VM
		_kvm_ga_enable ${1}

		# Activer la fonctionnalité "VM GenerationID" (AD / serveur Windows)
		_kvm_vmgenid_enable ${1}

		virsh start ${1} |grep -v '^$'
		if [ ${PIPESTATUS[0]} -ne 0 ] ; then
			ERROR "'virsh start' has failed for VM '${1}'"
			return 1
		fi

	fi

	return 0

else

	ERROR "can't start already running VM '${1}'"
	return 1

fi

}
	
function _kvm_shutdown { # Arrêter une VM
#- Arg 1 => nom de la VM

local snap

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

_kvm_is_freezed ${1}
if [ $? -eq 0 ] ; then
	_kvm_unfreeze ${1}
fi

_kvm_is_running ${1}
if [ $? -eq 0 ] ; then

	# Tentative d'arrêt avec l'agent
	virsh shutdown --mode agent  ${1} |grep -v '^$'

	# Echec ? => tentative d'arrêt avec ACPI
	[ ${PIPESTATUS[0]} -eq 0 ] || virsh shutdown ${1} --mode acpi |grep -v '^$'

	# Echec ? => arrêt (mode utilisé par défaut => ?)
	[ ${PIPESTATUS[0]} -eq 0 ] || virsh shutdown ${1} |grep -v '^$'

	# Supprimer la sauvegarde
	if [ -f ${KVM_BACKUP_DIR}/${1}.backup ] ; then
	
		rm ${KVM_BACKUP_DIR}/${1}.backup |grep -v '^$'
		WARNING "backup deleted for '${1}'"
	
	fi

	return 0

else

	ERROR "VM '${1}' is already stopped"
	return 1

fi

}

function _kvm_poweroff { # Forcer l'arrêt d'une VM
#- Arg 1 => nom de la VM

local snap

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

_kvm_is_running ${1} || _kvm_is_freezed ${1}
if [ $? -eq 0 ] ; then

	virsh destroy ${1} |grep -v '^$'
	
	# Supprimer la sauvegarde
	if [ -f ${KVM_BACKUP_DIR}/${1}.backup ] ; then
	
		rm ${KVM_BACKUP_DIR}/${1}.backup |grep -v '^$'
		WARNING "backup deleted for '${1}'"
	
	fi

	return 0

else

	ERROR "VM '${1}' is already stopped"
	return 1

fi

}

########################################################################

function _kvm_freeze { # Figer une VM
#- Arg 1 => nom de la VM

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

_kvm_is_running ${1}
if [ $? -eq 0 ] ; then
	virsh suspend ${1} |grep -v '^$'
fi

return 0

}

function _kvm_unfreeze { # Reprise d'une VM figée
#- Arg 1 => nom de la VM

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

_kvm_is_freezed ${1}
if [ $? -eq 0 ] ; then
	virsh resume ${1} |grep -v '^$'
	# Mise à l'heure de la VM
	_kvm_ga_timesync ${1}
fi

return 0

}

########################################################################

function _kvm_vmgenid_enable { # Activer VM GenerationID pour une VM
#- Arg 1 => nom de la VM
#- Vérification: virsh qemu-monitor-command NOM_VM --hmp info vm-generation-id

local b
local e
local f

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

# Copie du fichier XML d'origine
f=$(mktemp --suffix .xml)
cp ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml ${f}

_kvm_has_vmgenid ${1}

if [ $? -eq 0 ] ; then

	grep -q "vmgenid,guid=auto" ${f}
	if [ $? -ne 0 ] ; then

		sed -i "s/^<domain type='kvm'>/<domain type='kvm' xmlns:qemu='http:\/\/libvirt.org\/schemas\/domain\/qemu\/1.0'>\n  <qemu:commandline>\n   <qemu:arg value='-device'\/>\n   <qemu:arg value='vmgenid,guid=auto'\/>\n  <\/qemu:commandline>/g" ${f}
		virsh define ${f} |grep -v '^$' 2>/dev/null >/dev/null
	
		if [ ${PIPESTATUS[0]} -ne 0 ] ; then
			WARNING "'virsh define' has failed for VM '${1}'"
		fi
		
	fi

else

	grep -q "vmgenid,guid=auto" ${f}
	if [ $? -eq 0 ] ; then

		sed -i "s/^<domain type='kvm' xmlns:qemu='http:\/\/libvirt.org\/schemas\/domain\/qemu\/1.0'>/<domain type='kvm'>/g" ${f}
		b=$(grep -n -B2 -A1 "vmgenid,guid=auto" ${f} |head -1 |cut -d- -f1)
		e=$(grep -n -B2 -A1 "vmgenid,guid=auto" ${f} |tail -1 |cut -d- -f1)
		sed -i "${b},${e}d" ${f}
		virsh define ${f} |grep -v '^$' 2>/dev/null >/dev/null
	
		if [ ${PIPESTATUS[0]} -ne 0 ] ; then
			WARNING "'virsh define' has failed for VM '${1}'"
		fi		
		
	fi

fi

rm ${f}

return 0

}

function _kvm_ga_enable { # Activer Qemu Guest Agent pour une VM
#- Arg 1 => nom de la VM
#- Note: l'agent DOIT être installé manuellement dans la VM
#- Windows: "QEMU guest agent" (CD virtio-win-xxx.iso)
#- Ubuntu:  "apt-get install qemu-guest-agent"

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

grep -q "org\.qemu\.guest_agent\." ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml
if [ $? -ne 0 ] ; then

	sed "s/##KVM_GUEST##/${1}/g" < ${HVM_BASE}/etc/qemu-ga_tpl.xml > ${HVM_LOCK_DIR}/qemu-ga_${1}.xml
	virsh attach-device ${1} --persistent --file ${HVM_LOCK_DIR}/qemu-ga_${1}.xml |grep -v '^$' 2>/dev/null >/dev/null

	if [ ${PIPESTATUS[0]} -ne 0 ] ; then
		WARNING "'virsh attach-device' has failed for VM '${1}'"
	fi

	rm ${HVM_LOCK_DIR}/qemu-ga_${1}.xml

fi

return 0

}

function _kvm_ga_timesync { # Synchroniser l'horloge de la VM sur celle de l'hôte
#- Arg 1 => nom de la VM
#- Note: l'agent DOIT être installé manuellement dans la VM

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

sleep 1
virsh domtime --now ${1} 2>/dev/null >/dev/null

if [ ${PIPESTATUS[0]} -ne 0 ] ; then
	WARNING "'virsh domtime' has failed for VM '${1}'"
fi

return 0

}
