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

#virsh desc ${1} |egrep -q '^autostart=(yes|true|1)$'

#if [ $? -eq 0 ] ; then
	##return 0
#else
	##return 1
#fi
#return 0
###
local b
local e

b=$(grep -n "<urca:custom " ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |cut -d: -f1)
e=$(grep -n "</urca:custom>" ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |cut -d: -f1)
if [ ! -z "${b}" ] && [ ! -z "${e}" ] ; then
	sed -n "${b},${e}p" ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |grep -q "<autostart>enabled</autostart>"
	if [ $? -eq 0 ] ; then
		return 0
	else
		return 1
	fi
else
	return 1
fi

}

function _kvm_has_autobackup { # Vérifier si la VM peut être sauvegardée automatiquement
#- Arg 1 => nom de la VM
#- Codes retour:
#- 0 -> sauvegarde automatique activée
#- 1 -> sauvegarde automatique désactivée

#virsh desc ${1} |egrep -q '^autobackup=(yes|true|1)$'

#if [ $? -eq 0 ] ; then
	##return 0
#else
	##return 1
#fi
#return 0

local b
local e

b=$(grep -n "<urca:custom " ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |cut -d: -f1)
e=$(grep -n "</urca:custom>" ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |cut -d: -f1)
if [ ! -z "${b}" ] && [ ! -z "${e}" ] ; then
	sed -n "${b},${e}p" ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |grep -q "<autobackup>enabled</autobackup>"
	if [ $? -eq 0 ] ; then
		return 0
	else
		return 1
	fi
else
	return 1
fi

}

function _kvm_prio { # Afficher la priorité de la VM
#- Arg 1 => nom de la VM
#- priorité de 1 à 99, correspond à l'ordre d'activation de la VM
#- utiliser la liste inversée pour la désactivation
#- pas de priorité => 99 par défaut

#local p

#p=$(virsh desc ${1} |egrep '^prio=[0-9]+$')
#p=${p#*=}
#p=${p:-99}

#echo ${p}

#return 0
###########
local b
local e
local p

b=$(grep -n "<urca:custom " ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |cut -d: -f1)
e=$(grep -n "</urca:custom>" ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |cut -d: -f1)
if [ ! -z "${b}" ] && [ ! -z "${e}" ] ; then
	p=$(sed -n "${b},${e}p" ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml |egrep "<prio>[0-9]+</prio>" |sed "s/<prio>// ; s/<\/prio>//")
fi

p=${p:-99}
echo ${p}

return 0

}

function _kvm_has_ga { # Vérifier si le Guest-Agent est activé pour la VM
#- Arg 1 => nom de la VM
#- Codes retour:
#- 0 -> VM generationID activé
#- 1 -> VM generationID désactivé

grep -q "org\.qemu\.guest_agent\." ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml
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

grep -q "vmgenid,guid=auto" ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml
if [ $? -eq 0 ] ; then
	return 0
else
	return 1
fi

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
		_kvm_has_ga ${1} && _kvm_ga_timesync ${1}

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
	_kvm_has_ga && _kvm_ga_timesync ${1}
fi

return 0

}

########################################################################

function _kvm_setup_defaults { # Rélgages par défaut
#- Arg 1 => nom de la VM

_kvm_custom ${1} defaults
_kvm_setup_ga ${1} ${HVM_DEFAULT_KVM_GUESTAGENT}
_kvm_setup_vmgenid ${1} ${HVM_DEFAULT_KVM_VMGENID}

return 0

}

function _kvm_setup_autostart { # Gestion propriété "autostart"
#- Arg 1 => nom de la VM
#- Arg 2 => [enable|disable]

_kvm_custom ${1} autostart ${2}

return 0

}

function _kvm_setup_autobackup { # Gestion propriété "autobackup"
#- Arg 1 => nom de la VM
#- Arg 2 => [enable|disable]

_kvm_custom ${1} autobackup ${2}

return 0

}

function _kvm_setup_prio { # Gestion propriété "priorité"
#- Arg 1 => nom de la VM
#- Arg 2 => [00->99]

_kvm_custom ${1} prio ${2}

return 0

}

function _kvm_setup_vmgenid { # Activer "VM GenerationID" pour une VM
#- Arg 1 => nom de la VM
#- Arg 2 => enable|disable
#- Note: Vérification ID => "virsh qemu-monitor-command NOM_VM --hmp info vm-generation-id"

local b
local e
local f

# Copie du fichier XML d'origine
f=$(mktemp --suffix .xml)
cp ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml ${f}

case ${2} in
	enable)
		_kvm_has_vmgenid ${1}
		if [ $? -ne 0 ] ; then
			sed -i "s/^<domain type='kvm'>/<domain type='kvm' xmlns:qemu='http:\/\/libvirt.org\/schemas\/domain\/qemu\/1.0'>\n  <qemu:commandline>\n   <qemu:arg value='-device'\/>\n   <qemu:arg value='vmgenid,guid=auto'\/>\n  <\/qemu:commandline>/g" ${f}
			virsh define ${f} |grep -v '^$' 2>/dev/null >/dev/null
			if [ ${PIPESTATUS[0]} -ne 0 ] ; then
				WARNING "'virsh define' has failed for VM '${1}'"
			else
				echo -n "KVM '${1}' VM GenerationID is enabled"
			fi
		else
			echo -n "KVM '${1}' VM GenerationID is already enabled"
		fi
	;;
	disable)
		_kvm_has_vmgenid ${1}
		if [ $? -eq 0 ] ; then
			sed -i "s/^<domain type='kvm' xmlns:qemu='http:\/\/libvirt.org\/schemas\/domain\/qemu\/1.0'>/<domain type='kvm'>/g" ${f}
			b=$(grep -n -B2 -A1 "vmgenid,guid=auto" ${f} |head -1 |cut -d- -f1)
			e=$(grep -n -B2 -A1 "vmgenid,guid=auto" ${f} |tail -1 |cut -d- -f1)
			sed -i "${b},${e}d" ${f}
			virsh define ${f} |grep -v '^$' 2>/dev/null >/dev/null
			if [ ${PIPESTATUS[0]} -ne 0 ] ; then
				WARNING "'virsh define' has failed for VM '${1}'"
			else
				echo "KVM '${1}' VM GenerationID is disabled"
			fi
		else
			echo "KVM '${1}' VM GenerationID is already disabled"
		fi
	;;
	*)
		echo -n "KVM '${1}' VM GenerationID is "
		_kvm_has_vmgenid ${1} && echo -n "enabled" || echo -n "disabled"
		_kvm_is_running ${1}
		if [ $? -eq 0 ] ; then
			echo " => $(virsh qemu-monitor-command ${1} --hmp info vm-generation-id)"
		else
			echo
		fi
	;;
esac

rm ${f}

return 0

}

function _kvm_setup_ga { # Activer Qemu Guest Agent pour une VM
#- Arg 1 => nom de la VM
#- Arg 2 => enable|disable
#- Note: l'agent DOIT être installé manuellement dans la VM
#- Windows: "QEMU guest agent" (CD virtio-win-xxx.iso)
#- Ubuntu:  "apt-get install qemu-guest-agent"

local f

# Préparation du modèle pour l'ajout du GuestAgent
f=$(mktemp --suffix .xml)
sed "s/##KVM_GUEST##/${1}/g" < ${HVM_BASE}/etc/qemu-ga_tpl.xml > ${f}

case ${2} in
	enable)
		_kvm_has_ga ${1}
		if [ $? -ne 0 ] ; then
			virsh attach-device ${1} --config --file ${f} |grep -v '^$' 2>/dev/null >/dev/null
			if [ ${PIPESTATUS[0]} -ne 0 ] ; then
				WARNING "'virsh attach-device' has failed for VM '${1}'"
			else
				echo "KVM '${1}' GuestAgent is enabled"
			fi
		else
			echo "KVM '${1}' GuestAgent is already enabled"
		fi
	;;
	disable)
		_kvm_has_ga ${1}
		if [ $? -eq 0 ] ; then
			virsh detach-device ${1} --config --file ${f} |grep -v '^$' 2>/dev/null >/dev/null
			if [ ${PIPESTATUS[0]} -ne 0 ] ; then
				WARNING "'virsh detach-device' has failed for VM '${1}'"
			else
				echo "KVM '${1}' GuestAgent is disabled"
			fi
		else
			echo "KVM '${1}' GuestAgent is already disabled"
		fi
	;;
	*)
		echo -n "KVM '${1}' GuestAgent is "
		_kvm_has_ga ${1} && echo enabled || echo disabled
	;;
esac

rm ${f}

return 0

}

function _kvm_ga_timesync { # Synchroniser l'horloge de la VM sur celle de l'hôte
#- Arg 1 => nom de la VM
#- Note: l'agent DOIT être installé manuellement dans la VM

sleep 1
virsh domtime --now ${1} 2>/dev/null >/dev/null

if [ ${PIPESTATUS[0]} -ne 0 ] ; then
	WARNING "'virsh domtime' has failed for VM '${1}'"
fi

return 0

}

function _kvm_custom { # Gestion propriétés autostart,autobackup,prio
#- Arg 1 => nom de la VM
#- Arg 2 => propriété (autostart|autobackup|prio|defaults)
#- Arg 3 => enable|disable|00-99
#- Note: si Arg 2 ="defaults", applique les réglages par défaut

local b
local e
local f
local m
local c_autostart
local c_autobackup
local c_prio

# Lire les propriétés custom de la VM
_kvm_has_autostart ${1} && c_autostart=enabled || c_autostart=disabled
_kvm_has_autobackup ${1} && c_autobackup=enabled || c_autobackup=disabled
c_prio=$(_kvm_prio ${1})

case ${2} in

	autostart)
		case ${3} in
			enable)
				c_autostart="enabled"
				m=1
			;;
			disable)
				c_autostart="disabled"
				m=1
			;;
		esac
	;;

	autobackup)
		case ${3} in
			enable)
				c_autobackup="enabled"
				m=1
			;;
			disable)
				c_autobackup="disabled"
				m=1
			;;
		esac
	;;

	prio)
		if [ ! -z "${3}" ] &&  [ -z "$(echo -n ${3} |tr -d '0-9')" ] ; then
			c_prio="${3}"
			m=1
		fi
	;;

	defaults)
		c_autostart="${HVM_DEFAULT_KVM_AUTOSTART}"
		c_autobackup="${HVM_DEFAULT_KVM_AUTOBACKUP}"
		c_prio="${HVM_DEFAULT_KVM_PRIO}"
		m=1
	;;

esac

if [ ! -z "${m}" ] ; then
	# Copie du fichier XML d'origine
	f=$(mktemp --suffix .xml)
	cp ${KVM_LIBVIRT_ETC_DIR}/qemu/${1}.xml ${f}
	
	b=$(grep -n "<metadata>" ${f} |cut -d: -f1)
	e=$(grep -n "</metadata>" ${f} |cut -d: -f1)
	if [ ! -z "${b}" ] && [ ! -z "${e}" ] ; then
		# extraire une copie du bloc "metadata"
		sed -n "${b},${e}p" ${f} > ${f}.metadata
		# supprimer le bloc "metadata" du fichier XML
		sed -i "${b},${e}d" ${f}
		b=$(grep -n "<urca:custom " ${f}.metadata |cut -d: -f1)
		e=$(grep -n "</urca:custom>" ${f}.metadata |cut -d: -f1)
		if [ ! -z "${b}" ] && [ ! -z "${e}" ] ; then
			# supprimer le bloc "custom:urca"
			((b++))
			sed -i "${b},${e}d" ${f}.metadata
		fi
		sed -i "s/<\/metadata>//" ${f}.metadata
		cat<<EOF >> ${f}.metadata
<autostart>${c_autostart}</autostart>
<autobackup>${c_autobackup}</autobackup>
<prio>${c_prio}</prio>
</urca:custom>
</metadata>
EOF
	else
		cat<<EOF > ${f}.metadata
<metadata>
<urca:custom xmlns:urca="https://github.com/lspagnol/hvm/tree/master/doc">
<autostart>${c_autostart}</autostart>
<autobackup>${c_autobackup}</autobackup>
<prio>${c_prio}</prio>
</urca:custom>
</metadata>
EOF
	fi
	
	sed -i "s/<\/domain>//" ${f}
	cat ${f}.metadata >> ${f}
	echo "</domain>" >> ${f}
	
	virsh define ${f} |grep -v '^$' 2>/dev/null >/dev/null
	if [ ${PIPESTATUS[0]} -ne 0 ] ; then
		WARNING "'virsh define' has failed for VM '${1}'"
	fi

	rm ${f}
	rm ${f}.metadata

fi

case ${2} in
	autostart)
		echo "KVM '${1}' autostart is ${c_autostart}"
	;;
	autobackup)
		echo "KVM '${1}' autobackup is ${c_autobackup}"
	;;
	prio)
		echo "KVM '${1}' prio is ${c_prio}"
	;;
	defaults)
		echo "KVM '${1}' autostart is ${c_autostart}"
		echo "KVM '${1}' autobackup is ${c_autobackup}"
		echo "KVM '${1}' prio is ${c_prio}"
	;;
esac

return 0

}
