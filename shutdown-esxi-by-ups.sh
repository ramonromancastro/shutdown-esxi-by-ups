#!/bin/bash

# shutdown-esxi-by-ups.sh apaga automaticamente servidores VMware vSphere.
# Copyright (C) 2018  Ramón Román Castro <ramonromancastro@gmail.com>
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

# DESCRIPCIÓN

# Comprueba el tiempo restante de batería de los dispositivos UPS del CPD y
# comienza un apagado automático de los servidores si el tiempo restante es
# inferior al configurado.

# PRERREQUISITOS

# - vSphere CLI.
#   https://code.vmware.com/web/dp/tool/vsphere-cli
# - Thumbprint de cada uno de los hosts VMware vSphere que se desean administrar.
#   echo -n | openssl s_client -connect FQDN:443 2>/dev/null | openssl x509 -noout -fingerprint -sha1 | cut -d'=' -f2> FQDN.thumbprint
# - Paquete samba-common
# - Paquete mailx

# CONFIGURACIÓN A NIVEL DE SCRIPT

set -o pipefail     

# CONSTANTES

version=0.3.0
script=shutdown-esxi-by-ups

oid_upsBatteryStatus=.1.3.6.1.2.1.33.1.2.1.0
oid_upsEstimatedMinutesRemaining=.1.3.6.1.2.1.33.1.2.3

mail_Subject="${script}.sh - Apagado automático de servidores"

certs_Path=certs/

upsBatteryStatusValues=(none unknown batteryNormal batteryLow batteryDepleted)
exit_upsError=1
exit_upsPrerequisites=2
exit_upsConfig=3
exit_upsSecurity=4

cloginrc_file=etc/.cloginrc

# CONFIGURACION

cfg_minutesRemaining=10
cfg_upsDevices=
cfg_upsSnmpCommunity=
cfg_vmwareServers=
cfg_mailServer=
cfg_mailFrom=
cfg_mailTo=

# PARAMETROS

configFile=
force=
log=
generate=
debug=
dryRun=

# FUNCIONES

write_log(){
	[ -z $2 ] && tag=INFO || tag=$2
	tagi=
	tage=
	[ "$tag" == "ERROR" ] && tagi="\e[41m"; tage="\e[0m"
	[ "$tag" == "WARNING" ] && tagi="\e[33m" && tage="\e[0m"
	[ "$tag" == "DEBUG" ] && tagi="\e[36m" && tage="\e[0m"
	echo -e "[$(date +'%Y/%m/%d %H:%M:%S')] ${tagi}[${tag}] $1${tage}"
	[ $log ] && echo "[$(date +'%Y/%m/%d %H:%M:%S')] [$tag] $1" >> /var/log/${script}.log
}

debug_log(){
	[ $debug ] && write_log "$1" "DEBUG"
}

exit_log(){
	write_log "Fin de la ejecución."
	exit $1
}

mail_body(){
cat << EOF
Estimado ${cfg_mailTo},

Se ha ejecutado un apagado automático de los servidores desde el servidor ${HOSTNAME} mediante la ejecución del script ${script}.sh.

El archivo de configuración utilizado ha sido:

- ${configFile}

Los servidores afectados por este apagado automático han sido:

- ${cfg_vmwareServers[*]}

Los dipositivos UPS que han generado este apagado automático han sido:

- ${cfg_upsDevices[*]}

Para más detalles, consulte el archivo /var/log/${script}.log en el servidor ${HOSTNAME}.

Un saludo!

EOF
}

send_mail(){
	if [ ! -z "${cfg_mailServer}" ] && [ ! -z "${cfg_mailFrom}" ] && [ ! -z "${cfg_mailTo}" ]; then
		write_log "Enviando correo electrónico de aviso a ${cfg_mailTo}."
		mail_body | mailx -r "${cfg_mailFrom}" -s "${mail_Subject}" -S smtp="${cfg_mailServer}" "${cfg_mailTo}" > /dev/null
		if [ $? -ne 0 ]; then
			write_log "Ha ocurrido un error enviando el correo electrónico de aviso." "ERROR"
		fi
	fi
}

cloginrc_find(){
	ip=$1
	login=$2
	value=""
	while read -r line; do
		value=`grep "[[:space:]]*$login[[:space:]]*$ip[[:space:]]*" "$cloginrc_file" | awk '{ print $4 }'`
		if [ -z $value ]; then
			value=`grep "[[:space:]]*$login[[:space:]]*\*[[:space:]]*" "$cloginrc_file" | awk '{ print $4 }'`
		fi
	done < "$cloginrc_file"
	echo "${value}"
}

print_license(){
	echo "${script}.sh version ${version}, Copyright (C) 2018  Ramón Román Castro <ramonromancastro@gmail.com>"
	echo "This program comes with ABSOLUTELY NO WARRANTY; for details read LICENSE file."
	echo "This is free software, and you are welcome to redistribute it"
	echo "under certain conditions; read LICENSE file for details."
	echo
}

usage(){
cat << EOF
usage: ${script}.sh options

OPTIONS:
    --config    Config file
    --force     Force servers shutdown
    --log       Duplicate messages to /var/log/${script}.log
    --debug     Generate debug log
    --generate  Auto-generate thumbprints for all servers
    --dry-run   Execute without modifications
    --help      Show this help

EOF
	exit 0
}

# CUERPO PRINCIPAL

print_license

# Prerrequisitos

if ! which esxcli > /dev/null 2>&1; then
	write_log "No se localiza el comando [esxcli]. vSphere CLI debe estar instalado en el equipo." "ERROR"
	exit_log ${exit_upsPrerequisites}
fi

if ! which vmware-cmd > /dev/null 2>&1; then
	write_log "No se localiza el comando [vmware-cmd]. vSphere CLI debe estar instalado en el equipo." "ERROR"
	exit_log ${exit_upsPrerequisites}
fi

if ! which mailx > /dev/null 2>&1; then
	write_log "No se localiza el comando [mailx]. El paquete mailx debe estar instalado en el equipo." "ERROR"
	exit_log ${exit_upsPrerequisites}
fi

#if ! which net > /dev/null 2>&1; then
#	write_log "No se localiza el comando [net rpc]. El paquete samba-common debe estar instalado en el equipo." "ERROR"
#	exit_log ${exit_upsPrerequisites}
#fi

if [ -z $cloginrc_file ] || [ ! -f $cloginrc_file ]; then
	write_log "Archivo de seguridad no disponible." "ERROR"
	exit_log ${exit_upsSecurity}
fi

# Lectura de parámetros

if [ $# -eq 0 ]; then
	usage
	exit 0
fi
while [[ $# -gt 0 ]]; do
	key="$1"
	case $key in
		--config)
			shift
			configFile=$1
			;;
		--force)
			force=1
			;;
		--generate)
			generate=1
			;;
		--help)
			usage
			exit 0;
			;;
		--log)
			log=1
			;;
		--dry-run)
			dryRun=1
			;;
		--debug)
			debug=1
			;;
		*)
			usage
			exit 0
			;;
	esac
	shift
done

if [ -z $configFile ] || [ ! -f $configFile ]; then
	write_log "Archivo de configuración no disponible." "ERROR"
	exit_log ${exit_upsConfig}
else
	. $configFile
fi

write_log "Inicio de la ejecución."

debug_log "El tiempo límite restante de batería a comprobar es de ${cfg_minutesRemaining} minutos."
debug_log "Dispositivos UPS monitorizados: $(echo ${cfg_upsDevices[*]} | tr ' ' ',')."
debug_log "Servidores gestionados: $(echo ${cfg_vmwareServers[*]} | tr ' ' ',')."

if [ ${generate} ]; then
	for host in ${cfg_vmwareServers[*]}; do
		write_log "Generando SHA1 thumbprint del servidor ${host}." "INFO"
		echo -n | openssl s_client -connect ${host}:443 2>/dev/null | openssl x509 -noout -fingerprint -sha1 | cut -d'=' -f2> ${certs_Path}${host}.thumbprint
		if [ $? -ne 0 ]; then
			write_log "Ha ocurrido un error generando SHA1 thumbprint del servidor ${host}." "ERROR"
		fi
	done
	exit_log 0
fi

# Para cada dispositivo UPS
for upsDevice in ${cfg_upsDevices[*]}; do

	# Estado de la batería
	write_log "Conectando con el dispositivo UPS ${upsDevice}."
	upsBatteryStatus=$(snmpget ${cfg_upsSnmpAuth} -Oqv ${upsDevice} ${oid_upsBatteryStatus} 2> /dev/null)
	if [ -z ${upsBatteryStatus} ]; then
		write_log "Ha ocurrido un error conectando con el dispositivo UPS ${upsDevice} para recuperar el valor upsBatteryStatus." "ERROR"
		[ ! $force ] && exit_log ${exit_upsError}
	fi
	debug_log "La batería del dispositivo UPS ${upsDevice} se encuentra en estado ${upsBatteryStatusValues[$upsBatteryStatus]}."
	if [ ${upsBatteryStatusValues[$upsBatteryStatus]} == batteryNormal ]; then
		write_log "No hay que realizar ninguna acción."
		[ ! $force ] && exit_log 0
	fi

	# Tiempo restante de batería
	upsEstimatedMinutesRemaining=$(snmpget ${cfg_upsSnmpAuth} -Oqv ${upsDevice} ${oid_upsEstimatedMinutesRemaining} 2> /dev/null)
	if [ -z ${upsEstimatedMinutesRemaining} ]; then
		write_log "Ha ocurrido un error conectando con el dispositivo UPS ${upsDevice} para recuperar el valor upsEstimatedMinutesRemaining." "ERROR"
		[ ! $force ] && exit_log ${exit_upsError}
	fi

	debug_log "El tiempo restante de batería del dispositivo UPS ${upsDevice} es de ${upsEstimatedMinutesRemaining} minutos."
	# Comprobación de apagado automático
	if [ ${upsEstimatedMinutesRemaining} -ge ${cfg_minutesRemaining} ]; then
		write_log "No hay que realizar ninguna acción."
		[ ! $force ] && exit_log 0
	fi
done

if [ $force ]; then
	echo
	read -p $'\033[33mATENCIÓN, ¿está seguro que desea apagar los servidores [S/N]?\033[0m '
	echo
	if [[ ! $REPLY =~ ^[Ss]$ ]]; then
		exit_log 0
	fi
fi

# Apagado automático
if [ $dryRun ]; then
esxCLI=esxcli
write_log "Inicio del apagado automático."
for host in ${cfg_vmwareServers[*]}; do

	write_log "Recuperando las credenciales de acceso al servidor ${host}." "INFO"
	username=$(cloginrc_find "${host}" "user")
	password=$(cloginrc_find "${host}" "password")

	if [ -z $username ] || [ -z $password ]; then
		write_log "Ha ocurrido un error recuperando las credenciales de acceso al servidor ${host}." "ERROR"
		continue
	fi
	
	write_log "Conectando con el servidor ${host}."
	esxVersion=$(esxcli -s ${host} -u ${username} -p ${password} -d $(cat ${certs_Path}${host}.thumbprint) --formatter=keyvalue system version get 2> /dev/null | grep "VersionGet.Version.string" | cut -d'=' -f2)
	if [ $? -eq 0 ]; then
		debug_log "La versión del servidor ${host} es ${esxVersion}." "INFO"
		esxCLI=esxcli
	else
		esxcli -s ${host} -u ${username} -p ${password} -d $(cat ${certs_Path}${host}.thumbprint) vms vm list > /dev/null 2>&1
		if [ "$?" -eq 0 ]; then
			debug_log "La versión del servidor ${host} no está disponible." "INFO"
			esxCLI=vicfg-hostops
		else
			write_log "Ha ocurrido un error conectando con el servidor ${host}." "ERROR"
			continue
		fi
	fi
	
	write_log "Recolectando las máquinas virtuales del servidor ${host}."
	virtualMachines=($(vmware-cmd -H ${host} -U ${username} -P ${password} -l 2> /dev/null))
	if [ "$?" != 0 ]; then
		write_log "Ha ocurrido un error recolectando las máquinas virtuales del servidor ${host}." "WARNING"
	else
		for vm in ${virtualMachines[*]}; do
			write_log "Apagando la máquina virtual ${vm##*/}."
			vmware-cmd -H ${host} -U ${username} -P ${password} ${vm} stop soft > /dev/null 2>&1
			if [ "$?" != 0 ]; then
				write_log "Ha ocurrido un error apagando la máquina virtual ${vm}." "WARNING"
			fi
		done
	fi
	
	write_log "Activando el modo mantenimiento en el servidor ${host}."
	if [ "${esxCLI}" == "esxcli" ]; then
		# ESXi 5+
		maintenanceMode=$(esxcli -s ${host} -u ${username} -p ${password} -d $(cat ${certs_Path}${host}.thumbprint) system maintenanceMode get 2> /dev/null)
		if [ "$?" != 0 ]; then
			write_log "Ha ocurrido un error recuperando el estado del servidor ${host}." "ERROR"
			continue
		fi
		
		if [ "$maintenanceMode" != "Enabled" ]; then
			esxcli -s ${host} -u ${username} -p ${password} -d $(cat ${certs_Path}${host}.thumbprint) system maintenanceMode set --enable true > /dev/null 2>&1
			if [ "$?" != 0 ]; then
				write_log "Ha ocurrido un error estableciendo del modo mantenimiento en el servidor ${host}." "ERROR"
				continue
			fi
		else
			write_log "El servidor ${host} ya se encontraba en modo mantenimiento." "INFO"
		fi
		
		write_log "Apagando el servidor ${host}."
		esxcli -s ${host} -u ${username} -p ${password} -d $(cat ${certs_Path}${host}.thumbprint) system shutdown poweroff --reason "${script}.sh" --delay 10 > /dev/null 2>&1
		if [ "$?" != 0 ]; then
			write_log "Ha ocurrido un error apagando el servidor ${host}." "ERROR"
			continue
		fi
	else
		# ESXi 4
		write_log "Activando el modo mantenimiento en el servidor ${host}."
		maintenanceMode=$(vicfg-hostops --server ${host} --username ${username} --password ${password} --operation info 2> /dev/null | grep "In Maintenance Mode" | cut -d':' -f2 | awk '{ print $1 }')
		if [ "$?" != 0 ]; then
			write_log "Ha ocurrido un error recuperando el estado del servidor ${host}." "ERROR"
			continue
		fi
		if [ "$maintenanceMode" != "yes" ]; then
			vicfg-hostops --server ${host} --username ${username} --password ${password} --operation enter --action poweroff > /dev/null 2>&1
			if [ "$?" != 0 ]; then
				write_log "Ha ocurrido un error estableciendo del modo mantenimiento en el servidor ${host}." "ERROR"
				continue
			fi
		fi
		write_log "Apagando el servidor ${host}."
		vicfg-hostops --server ${host} --username ${username} --password ${password} --operation shutdown > /dev/null 2>&1
		if [ "$?" != 0 ]; then
			write_log "Ha ocurrido un error apagando el servidor ${host}." "ERROR"
			continue
		fi
	fi
done
fi

send_mail

write_log "Fin del apagado automático."

exit_log 0
