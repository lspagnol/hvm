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

if [ -f ${KVM_BACKUP_DIR}/${1}.save ] ; then
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
#- Arg 2 => timestamp

if [ -z "${2}" ] ; then
	ERROR "timestamp is required"
	return 1
fi

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

mkdir -p ${HVM_TMP_DIR}/backups

_kvm_is_running ${1} || _kvm_is_freezed ${1}
if [ $? -eq 0 ] ; then

	_kvm_has_snapshot ${1}
	if [ $? -eq 0 ] ; then
	
		# 'virsh save' ne fonctionne pas correctement avec des snapshots KVM => utiliser les snapshots KVM
		WARNING "using 'snapshot-create-as' instead of 'save' for '${1}'"
		virsh snapshot-create-as ${1} --name ${1}@${2} --halt |grep -v '^$'
		if [ ${PIPESTATUS[0]} -ne 0 ] ; then
			ERROR "'virsh snapshot-create-as' has failed"
			return 1
		else
			echo "${2}" > ${HVM_TMP_DIR}/backups/${1}
			return 0
		fi
	
	else
	
		virsh managedsave ${1} |grep -v '^$'
		if [ ${PIPESTATUS[0]} -ne 0 ] ; then
			ERROR "'virsh managedsave' has failed"
			return 1
		else
			touch ${HVM_TMP_DIR}/backups/${1}
			return 0
		fi
	
	fi

else

	ERROR "can't backup stopped VM '${1}'"
	return 1

fi

sleep 1

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

		snap=$(<${HVM_TMP_DIR}/backups/${1})
		if [ -z "${snap}" ] ; then
			# La VM a été sauvegardée avec 'managedsave'

			virsh start ${1} |grep -v '^$'
			if [ ${PIPESTATUS[0]} -ne 0 ] ; then
				ERROR "'virsh start' has failed for VM '${1}'"
				return 1
			fi

			rm ${HVM_TMP_DIR}/backups/${1}

			# Mise à l'heure de la VM
			_kvm_ga_timesync ${1}

			return 0

		else
			# La VM a été sauvegardée avec 'snapshot-create-as'

			virsh snapshot-revert ${1} --snapshotname ${1}@${snap} --running |grep -v '^$'
			if [ ${PIPESTATUS[0]} -ne 0 ] ; then
				ERROR "'virsh snapshot-revert' has failed for VM '${1}'"
				return 1
			fi
			echo "Domain snapshot ${1}@${snap} restored"

			# Mise à l'heure de la VM
			sleep 1
			_kvm_ga_timesync ${1}

			virsh snapshot-delete ${1} --snapshotname ${1}@${snap} |grep -v '^$'
			if [ ${PIPESTATUS[0]} -ne 0 ] ; then
				ERROR "'virsh snapshot-delete' has failed for VM '${1}'"
				return 1
			fi

			rm ${HVM_TMP_DIR}/backups/${1}

			return 0

		fi

	else

		ERROR "VM '${1}' has no backup/snapshot"
		return 1

	fi

else

	ERROR "can't restore already running or freezed VM '${1}'"
	return 1

fi

sleep 1

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

sleep 1

}
	
function _kvm_shutdown { # Arrêter une VM
#- Arg 1 => nom de la VM

local snap

if [ -z "${1}" ] ; then
	ERROR "VM name is required"
	return 1
fi

_kvm_is_freezed ${1} && _kvm_unfreeze ${1}

_kvm_is_running ${1}
if [ $? -eq 0 ] ; then

	# Tentative d'arrêt avec l'agent
	virsh shutdown --mode agent  ${1} |grep -v '^$'

	# Echec ? => tentative d'arrêt avec ACPI
	[ ${PIPESTATUS[0]} -eq 0 ] || virsh shutdown ${1} --mode acpi |grep -v '^$'

	# Echec ? => arrêt (mode utilisé par défaut => ?)
	[ ${PIPESTATUS[0]} -eq 0 ] || virsh shutdown ${1} |grep -v '^$'

	# Supprimer la sauvegarde
	if [ -f ${KVM_BACKUP_DIR}/${vm}.save ] ; then
	
		WARNING "backup deleted for '${1}'"
		virsh managedsave-remove ${1} |grep -v '^$'
	
	fi
	
	# Supprimer le snapshot HVM
	if [ -f ${HVM_TMP_DIR}/backups/${1} ] ; then

		snap=$(<${HVM_TMP_DIR}/backups/${1})
	
		if [ ! -z "${snap}" ] ; then
	
				virsh snapshot-delete ${1} --snapshotname ${1}@${snap} |grep -v '^$'
				WARNING "snapshot '${1}@${snap}' deleted"
	
				if [ ${PIPESTATUS[0]} -ne 0 ] ; then
					ERROR "'virsh snapshot-delete' has failed for VM '${1}'"
				fi	
	
		fi
		
		rm ${HVM_TMP_DIR}/backups/${1}
	
	fi

	return 0

else

	ERROR "VM '${1}' is already stopped"
	return 1

fi

sleep 1

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
	if [ -f ${KVM_BACKUP_DIR}/${1}.save ] ; then
	
		WARNING "backup deleted for '${1}'"
		virsh managedsave-remove ${1} |grep -v '^$'
	
	fi

	# Supprimer le snapshot HVM
	if [ -f ${HVM_TMP_DIR}/backups/${1} ] ; then
	
		snap=$(<${HVM_TMP_DIR}/backups/${1})

		if [ ! -z "${snap}" ] ; then

				virsh snapshot-delete ${1} --snapshotname ${1}@${snap} |grep -v '^$'
				WARNING "snapshot '${1}@${snap}' deleted"

				if [ ${PIPESTATUS[0]} -ne 0 ] ; then
					ERROR "'virsh snapshot-delete' has failed for VM '${1}'"
				fi	

		fi

		rm ${HVM_TMP_DIR}/backups/${1}

	fi

	return 0

else

	ERROR "VM '${1}' is already stopped"
	return 1

fi

sleep 1

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
