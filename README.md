# shutdown-esxi-by-ups

Automatic shutdown of ESXi server depending on the status of the associated UPS devices.

## Funcionamiento general

Este script lee el estado de los dispositivos UPS monitorizados y lanza una apagado automático de los servidores ESXi si se cumplen las siguientes condiciones:

1. El estado de las baterías de los dispositivos UPS es distinto a batteryNormal.
2. El tiempo restante de batería de los dispotivos UPS es inferior al especificado en la configuración.

Si alguna de las condiciones no se cumple, no se realizará el apagado automático.

## Versiones soportadas

Actualmente, las versiones en las cuales se ha probado el funcionamiento del script son:

- VMware ESX 4.x
- VMware ESXi 4.x
- VMware ESXi 6.x

## Prerrequisitos

- mailx
- snmpget
- vSphere CLI
  - esxcli
  - vmware-cmd

## Instalación

Hay que descargar el archivo **install.sh** adjunto al Release correspondiente y ejecutarlo en la ruta raíz donde se ha instalado el script. Una vez ejecutado, eliminar el archivo.

Este proceso de instalación crea los archivos de configuración iniciales a partir de las plantillas y modifica los permisos de los directorios y archivos para securizar la instalación.

## Configuración

### certs/

En este directorio se almacenan las thumbprint de los certificados de cada uno de los servidores, para un correcto funcionamiento de la aplicación esxcli.

El script incluye el parámetro --generate, que se encarga de generar estos archivos para cada uno de los servidores especificados en el archivo de configuración.

### etc/.cloginrc

Este archivo de configuración contiene las credenciales de acceso para cada uno de los servidores ESXi. El formato del archivo es una simplificación del formato utilizado por los archivos de configuración del tipo *clogin configuration file*.

Los valores que se pueden utilizar son los siguientes:

- add user SERVIDOR USERNAME
- add password SERVIDOR PASSWORD

donde SERVIDOR es el nombre del servidor que se define en el archivo de configuración. Se puede especificar *, en cuyo caso, se utilizará para todos los servidores

Un ejemplo de configuración es:

```
add user vm01.domain.local administrator
add user vm02.domain.local administrator
add user * root
add password * P@$$w0rd
```

### etc/default.conf

Este es el archivo de configuración por defecto. Dado que este archivo se pasa como parámetro a la ejecución del script, pueden definirse todos los que se necesiten, dependiendo de los diferentes entornos que deseemos gestionar.

Los valores de configuración disponibles son:

- **cfg_minutesRemaining=MINUTES**, donde MINUTES es el tiempo mínimo de batería de un dispositivo UPS antes de ejecutar un apagado automático.
- **cfg_upsDevices=(DEVICE_1 ... DEVICE_N)**, donde DEVICE_xx son los dispositivos UPS monitorizados.
- **cfg_upsSnmpAuth=("-v2c -c public" "-v2c -c public")**, es la configuración de acceso SNMP a cada uno de los dispositivos UPS.
- **cfg_vmwareServers=(SERVER_1 ... SERVER_N)**, donde SERVER_xx son los servidores gestionados.
- **cfg_mailServer=MAIL_SERVER**, donde MAIL_SERVER es el nombre del servidor de correo electrónico.
- **cfg_mailFrom="FROM_MAIL"**, donde FROM_MAIL es la dirección de correo electrónico del remitente.
- **cfg_mailTo="TO_MAIL"**, donde TO_MAIL es la dirección de correo electrónico del destinatario.

Un ejemplo de configuración es:

```
cfg_minutesRemaining=10
cfg_upsDevices=(192.168.1.1 192.168.1.2)
cfg_upsSnmpAuth=("-v2c -c public" "-v2c -c public")
cfg_vmwareServers=(vm01.domain.local vm02.domain.local vm03.domain.local)
cfg_mailServer=mail.domain.local
cfg_mailFrom="shutdown-esxi-by-ups.sh <from@domain.local>"
cfg_mailTo=to@domain.local
```
