#!/bin/bash

########################################################################
# Fonctions ZFS
########################################################################

function _zfs_mount { # Monter les volumes de stockage des VMs
#- return 0
#-

source ${HVM_BASE}/etc/zfs_mount.sh 2>/dev/null >/dev/null || ABORT "unable to execute '${HVM_BASE}/etc/zfs_mount.sh'"

return $?

}

function _zfs_umount { # Démonter les volumes de stockage des VMs
#- return 0
#-

local e v

_hv_status && ABORT "not allowed while libvirt is running"
_kvms_status && ABORT "not allowed while VMs are running"

source ${HVM_BASE}/etc/zfs_umount.sh

return $?

}

function _zfs_snap_list_all {

zfs list -t snapshot -H |awk '{print $1}' |egrep "^(${HVM_ZVOLS// /|})(/|@)"

}

function _zfs_snap_list_dates {

local snap snaps
snaps=$(_zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq)

for snap in ${snaps} ; do
	echo -n "${snap} "
	ls ${HVM_TMP_DIR}/.zfs 2>/dev/null >/dev/null
	if [ $? -eq 0 ] ; then
		ls ${HVM_TMP_DIR}/.zfs/snapshot/${snap}/backups/* 2>/dev/null >/dev/null
		if [ $? -eq 0 ] ; then
			echo -n "B "
		else
			echo -n "- "
		fi
		umount ${HVM_TMP_DIR}/.zfs/snapshot/${snap}
	else
		# Le volume n'est pas monté, impossible de vérifier s'il existe
		# des sauvegardes
		echo -n "? "
	fi
	date -d @${snap} +"%d/%m/%Y %T (%a)"
done

}

function _zfs_snap_list_lasts {

local zvol

for zvol in ${HVM_ZVOLS} ; do
	_zfs_snap_list_all |grep "^${zvol}@" |tail -1
done

}

function _zfs_snap_compare {

local r

_zfs_snap_list_all |grep "@${1}$" |sort > /tmp/hvm.lock/snaps.host_loc
ssh ${node_rem} "hvm func _zfs_snap_list_all" |grep "@${1}$" |sort > /tmp/hvm.lock/snaps.host_rem

diff /tmp/hvm.lock/snaps.host_loc /tmp/hvm.lock/snaps.host_rem 2>/dev/null >/dev/null
r=${?}

rm /tmp/hvm.lock/snaps.host_loc
rm /tmp/hvm.lock/snaps.host_rem

return ${r}

}

function _zfs_snap_create { # Créer des snapshots ZFS
# Arg 1 -> timestamp

if [ -z "${1}" ] ; then
	ERROR "timestamp is required"
	return 1
fi

_hv_status || ABORT "snapshot create is allowed only while libvirt is running"

local zvol

for zvol in ${HVM_ZVOLS} ; do
	echo "Recursive ZFS snapshot '${zvol}@${1}'"
	zfs snapshot -r ${zvol}@${1}
done

return 0

}

function _zfs_snap_sync {

_hv_status || ABORT "snapshot sync is allowed only while libvirt is running"

local t0 t1
local zvol

for zvol in ${HVM_ZVOLS} ; do

	t0=$(ssh ${node_rem} "hvm zfs snap list lasts" |grep "^${zvol}@")
	t0=${t0#*@}
	t1=$(_zfs_snap_list_lasts |grep "^${zvol}@")
	t1=${t1#*@}
	echo "Recursive send/receive ZFS snapshot - local '${zvol}@${t1}' - remote '${zvol}@${t0}'"

	# Transfert avec mbuffer (ne pas paralléliser)
	# zfs send -RLeI ${zvol}@${t0} ${zvol}@${t1} | mbuffer -q -v 0 -s 128k -m 1G |ssh ${node_rem} "mbuffer -s 128k -m 1G |zfs receive ${zvol}"

	# Transfert parallélisé avec dédup (pas efficace)
	#(
	#	zfs send -DRLeI ${zvol}@${t0} ${zvol}@${t1} |ssh ${node_rem} zfs receive ${zvol}
	#) &

	# Transfert parallélisé sans compression
	#(
	#	zfs send -RLeI ${zvol}@${t0} ${zvol}@${t1} |ssh ${node_rem} zfs receive ${zvol}
	#) &

	# Transfert parallélisé avec compression LZ4
	(
		zfs send -RLeI ${zvol}@${t0} ${zvol}@${t1} |lz4 |ssh ${node_rem} "unlz4 |zfs receive ${zvol}"
	) &

done

wait

}

function _zfs_snap_rollback {

_kvms_status && ABORT "snapshot rollback is not allowed while qemu is running"
_hv_status && ABORT "snapshot rollback is not allowed while libvirt is running"

local zvol subvol snap

for zvol in ${HVM_ZVOLS} ; do
	if [ "${1}" = "lasts" ] ; then
	        for subvol in $(zfs list -r ${zvol} -H |awk '{print $1}') ; do
	                snap=$(zfs list -t snapshot -H |awk '{print $1}' |grep "^${subvol}@" |tail -1)
					echo "Rollback to last ZFS snapshot '${snap}'"
	                zfs rollback ${snap}
	        done
	else
	        for snap in $(zfs list -t snapshot -H |awk '{print $1}' |egrep "^${zvol}(/|@)" |grep "@${1}$") ; do
			echo "Recursive rollback to ZFS snapshot '${snap}'"
	                zfs rollback -r ${snap}
	        done
	fi
done

}

function _zfs_snap_purge {

local e now ret flts flt
local snap snaps psnapsl psnapsr
local dataset ts th dts
local vol subvol

if [ "${1}" = "-e" ] ; then
	# "-e" passé en premier argument -> exécuter la suppression
	e=1
	shift
fi

flts="${HVM_SNAPSHOT_PURGE}"

now=$(date +%s)

# Récupérer la liste des snapshots
snaps=$(_zfs_snap_list_all)
if [ "${snaps}" = "" ] ; then
	ERROR "could not get local snapshots list"
	return 1
fi

# Récupérer les timestamp des derniers snapshots locaux
# -> ils ne devront pas être supprimés
psnapsl=$(_zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -${HVM_KEEP_LASTS_ZFS_SNAPSHOTS})
if [ "${psnapsl}" = "" ] ; then
	ERROR "could not get lasts local snapshots list"
	return 1
fi

# Récupérer les timestamp des derniers snapshots sur le noeud distant
# -> ils ne devront pas être supprimés
psnapsr=$(ssh ${node_rem} hvm func _zfs_snap_list_all |sed 's/^.*@//g' |sort |uniq |tail -${HVM_KEEP_LASTS_ZFS_SNAPSHOTS})
if [ "${psnapsr}" = "" ] ; then
	ERROR "could not get lasts remote snapshots list"
	return 1
fi

psnapsl=$(echo ${psnapsl} |sed "s/ /|/g")
echo "Lasts local snapshots : '${psnapsl}'"

psnapsr=$(echo ${psnapsr} |sed "s/ /|/g")
echo "Lasts remote snapshots: '${psnapsr}'"

echo "Forbid deletion of snapshots '${psnapsl}|${psnapsr}'"
echo

for flt in ${flts} ; do

	ret=${flt%:*} 
	flt=${flt#*:}

	if [ -z "${flt}" ] ; then
		WARNING "snapshots older than '${ret}' hours will be deleted"
	else
		WARNING "snapshots older than '${ret}' hours AND not matching filter '${flt:-NONE}' will be deleted"
	fi

	ret=$(( ${ret} * 3600 ))

	for zvol in ${HVM_ZVOLS} ; do
	
		for subvol in $(zfs list -r ${zvol} -H |awk '{print $1}') ; do
	
			for snap in $(echo "${snaps}" |grep "^${subvol}@" |sort -n) ; do
	
				# Extraction dataset
				dataset=${snap%@*}
	
				# Extraction timestamp snapshot
				ts=${snap#*@}
	
				# Timestamp => Heure au format MMHH
				th=$(date -d @${ts} +"%H%M")
	
				# Delta timestamp actuel - timestamp snapshot
				dts=$(( ${now} - ${ts} ))
	
				# Affichage: snapshot - delta - date lisible
				echo -n "${snap} - $(( ${dts} / 3600 )) - $(date -d @${ts} +"%d/%m/%Y %T (%a)") - "
				echo -n "delete: "
	
				if [ ${dts} -ge ${ret} ] ; then
					# Delta supérieur à rétention
	
					if [ ! -z "${flt}" ] ; then
						echo "${th}" |grep -q "^${flt}$"
						if [ $? -eq 0 ] ; then
							# L'heure correspond au motif de filtrage
							echo "no (filter)"
						else
							echo "${ts}" |egrep -q "^(${psnapsl}|${psnapsr})$"
							if [ $? -eq 0 ] ; then
								# Suppression des derniers snapshots interdite
								echo "no (lasts) - END"
								break
							else
								echo "yes"
								[ "${e}" = "1" ] && zfs destroy ${snap}
							fi
						fi
					else
						echo "${ts}" |egrep -q "^(${psnapsl}|${psnapsr})$"
						if [ $? -eq 0 ] ; then
							# Suppression des derniers snapshots interdite
							echo "no (lasts) - END"
							break
						else
							echo "yes"
							[ "${e}" = "1" ] && zfs destroy ${snap}
						fi
					fi
				else
					# Delta inférieur à rétention
					echo "no (delta) - END"
					break
				fi
	
			done
	
		done
	
	done

echo

done

}
