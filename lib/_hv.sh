#!/bin/bash

########################################################################
# Fonctions HV (contrôle de l'hyperviseur)
########################################################################

function _hv_status { # Récupérer / afficher état de libvirt
#- Arg 1 => '-v' => afficher état
#- Codes retour:
#- 0 -> libvirt fonctionne
#- 1 -> libvirt est arrêté

[ "${1}" = "-v" ] && echo -n "Hypervisor is "

if [ -f /etc/init.d/libvirtd ] ; then
	systemctl status libvirtd 2>/dev/null >/dev/null
else
	systemctl status libvirt-bin 2>/dev/null >/dev/null
fi

if [ $? -eq 0 ] ; then
	[ "${1}" = "-v" ] && echo "running"
	return 0
else
	[ "${1}" = "-v" ] && echo "stopped"
	return 1
fi

}

function _hv_start { # Démarrer libvirt

_hv_status && ABORT "libvirt is already running"

source ${HVM_BASE}/etc/hv_pre-start.sh

# Neutraliser le démarrage automatique natif des VMs/libvirt
rm ${KVM_LIBVIRT_ETC_DIR}/qemu/autostart/*.xml 2>/dev/null

# Démarrage libvirt
service virtlogd start
service virtlockd start
if [ -f /etc/init.d/libvirtd ] ; then
	service libvirtd start
else
	service libvirt-bin start
fi

if [ ${?} -eq 0 ] ; then
	if [ "${HVMD_HV_AUTOSTART}" = "1" ] ; then
		date > /var/lib/HV_WAS_RUNNING_HERE
	fi
fi

return 0

}

function _hv_stop { # Arrêter libvirt

_hv_status || ABORT "libvirt is already stopped"

# Arrêt libvirt
if [ -f /etc/init.d/libvirtd ] ; then
	service libvirtd stop
else
	service libvirt-bin stop
fi

if [ ${?} -eq 0 ] ; then
	[ -f /var/lib/HV_WAS_RUNNING_HERE ] && rm /var/lib/HV_WAS_RUNNING_HERE
fi

service virtlockd stop
service virtlogd stop

# Neutraliser le démarrage automatique natif des VMs/libvirt
rm ${KVM_LIBVIRT_ETC_DIR}/qemu/autostart/*.xml 2>/dev/null

source ${HVM_BASE}/etc/hv_post-stop.sh

return 0

}

function _hv_sharedIP_status { # Etat de l'adresse IP partagée sur l'hôte local
#- Arg 1 => '-v' => afficher état
#- Codes retour:
#- 0 -> l'adresse partagée est activée
#- 1 -> l'adresse partagée n'est pas activée

[ "${1}" = "-v" ] && echo -n "Shared IP is "
ip address |grep -q "inet ${HVM_SHARED_IP//./\\.}/"
if [ $? -eq 0 ] ; then
	echo "enabled"
	return 0
else
	echo "disabled"
	return 1

fi

}

function _hv_sharedIP_enable { # Activer l'adresse IP partagée de l'hyperviseur

# Vérifier si l'adresse IP partagée est utilisée
ping -q -c 2 -W 1 ${HVM_SHARED_IP} 2>/dev/null >/dev/null && ABORT "shared IP is already in use"
arping -q -w 100000 -c 2 ${HVM_SHARED_IP} && ABORT "shared IP '${HVM_SHARED_IP}' is already in use"

# Vérifier si le routeur le plus proche est joignable
ping -q -c 2 -W 1 ${HVM_GATEWAY} 2>/dev/null >/dev/null || ABORT "gateway is unreachable"

# Ajouter l'adresse IP partagée et forcer la mise à jour des caches ARP
ip address add ${HVM_SHARED_IP}/24 dev ${HVM_SERVICE_IFACE}
(arping -q -w 100000 -c 5 -S ${HVM_SHARED_IP} -i ${HVM_SERVICE_IFACE} ${HVM_GATEWAY}) &
(arping -q -w 100000 -c 5 -S ${HVM_SHARED_IP} -i ${HVM_SERVICE_IFACE} -B) &
wait

return 0

}

function _hv_sharedIP_disable { # Désactiver l'adresse IP partagée de l'hyperviseur

# Supprimer l'adresse IP partagée
ip address del ${HVM_SHARED_IP}/24 dev ${HVM_SERVICE_IFACE} 2>/dev/null

return 0

}

#function _hv_virtIF_status { # Afficher l'état des interfaces de virtualisation

#local vlan

#if [ "${HVM_VMS_IFACE}" != "" ] ; then
	#for vlan in ${HVM_VLANS_ID} ; do
		#if [ "${vlan}" != "0" ] ; then
			#echo -n "vlan${vlan} is "
			#ip link show vlan${vlan} 2>/dev/null |grep -q " state UP "
			#if [ $? -eq 0 ] ; then
				#echo "UP"
			#else
				#echo "DOWN"
			#fi
		#else
			#echo -n "native is "
			#ip link show native 2>/dev/null |grep -q " state UP "
			#if [ $? -eq 0 ] ; then
				#echo "UP"
			#else
				#echo "DOWN"
			#fi
		#fi
	#done
#fi

#return 0			

#}

#function _hv_virtIF_enable { # Activer les interfaces de virtualisation

#local vlan

## Interface utilisée par les machines virtuelles
##HVM_VMS_IFACE="bond1"

## Numéros des VLANs à activer pour les machines virtuelles
## -> ID=0 -> mode natif
##HVM_VLANS_ID="51 95"

#if [ "${HVM_VMS_IFACE}" != "" ] ; then
	#ip link set ${HVM_VMS_IFACE} up
	#lsmod |grep -q "^8021q" || modprobe 8021q
	#for vlan in ${HVM_VLANS_ID} ; do
		#if [ "${vlan}" != "0" ] ; then
			#vconfig add ${HVM_VMS_IFACE} ${vlan} >/dev/null
			#brctl addbr vlan${vlan}
			#brctl stp vlan${vlan} off
			#brctl addif vlan${vlan} ${HVM_VMS_IFACE}.${vlan}
			#ip link set vlan${vlan} up
		#else
			#brctl addbr native
			#brctl stp native off
			#brctl addif native ${HVM_VMS_IFACE}
			#ip link set native up
		#fi
	#done
#fi

#return 0

#}

#function _hv_virtIF_disable { # Désactiver les interfaces de virtualisation

#local vlan

#if [ "${HVM_VMS_IFACE}" != "" ] ; then
	#for vlan in ${HVM_VLANS_ID} ; do
		#if [ "${vlan}" != "0" ] ; then
			#ip link set vlan${vlan} down
			#brctl delif vlan${vlan} ${HVM_VMS_IFACE}.${vlan}
			#brctl delbr vlan${vlan}
			#vconfig rem ${HVM_VMS_IFACE}.${vlan} >/dev/null
		#else
			#ip link set native down
			#brctl delif native ${HVM_VMS_IFACE}
			#brctl deldbr native
		#fi
	#done
	#ip link set ${HVM_VMS_IFACE} down
#fi

#return 0

#}
