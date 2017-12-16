# Opérations à effectuer AVANT le démarrage de libvirt

# Monter les dossiers utilisés par libvirt
_zfs_mount

# Indiquer le nom de l'hyperviseur actif dans le pool de stockage par défaut
local _h
chattr -i ${KVM_LIBVIRT_VARLIB_DIR}/images
for _h in ${HVM_HOSTS} ; do
	if [ -f ${_h} ] ; then
		rm ${KVM_LIBVIRT_VARLIB_DIR}/${_h}
	fi
done
touch "${KVM_LIBVIRT_VARLIB_DIR}/images/${HOSTNAME}"
chattr +i ${KVM_LIBVIRT_VARLIB_DIR}/images
