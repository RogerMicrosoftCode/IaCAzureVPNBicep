Landing Zone de conectividad híbrida Azure con OPNsense
Descripción
Este repositorio contiene la definición de Infrastructure as Code para desplegar una landing zone de conectividad híbrida en Microsoft Azure.

La solución conecta una o más oficinas con Azure mediante VPN Site-to-Site, IPsec/IKEv2 y firewalls OPNsense.

Está diseñada para oficinas cuya conexión de Internet utiliza una dirección IPv4 pública dinámica. Cada firewall OPNsense publica su dirección mediante Dynamic DNS y Azure identifica la oficina mediante un FQDN estable.

La infraestructura se implementa utilizando:

Azure Bicep
Azure CLI
Azure VPN Gateway
Azure Virtual Network
VNet Peering
Gateway Transit
Azure Network Security Groups
OPNsense
Dynamic DNS
IPsec/IKEv2
Azure Key Vault opcional
Azure Firewall opcional
Azure Bastion opcional
Azure Private DNS opcional
Entorno objetivo
Configuración	Valor
Subscription ID	55318ed6-5d8a-4bd2-889f-10e502960c28
Resource Group	APPSEROGERVPN
Región predeterminada	Mexico Central
Herramienta IaC	Bicep
Topología	Hub-Spoke
Conectividad híbrida	Azure VPN Gateway
VPN	Site-to-Site
Protocolo	IPsec/IKEv2
Endpoint de oficina	FQDN mediante DDNS
El Resource Group debe existir antes del despliegue. La solución no debe crear ni eliminar el Resource Group APPSEROGERVPN.

Objetivos
La solución tiene los siguientes objetivos:

Centralizar la conectividad híbrida en una Hub VNet.
Conectar las oficinas mediante Azure VPN Gateway.
Compartir el VPN Gateway con los Spokes mediante Gateway Transit.
Aislar las aplicaciones en redes Spoke independientes.
Evitar el uso de rangos 192.168.x.x dentro de Azure.
Permitir que las redes de oficina continúen utilizando rangos 192.168.x.x.
Soportar IP pública dinámica en las oficinas mediante DDNS.
Evitar el almacenamiento de secretos dentro del repositorio.
Permitir agregar nuevas oficinas y Spokes mediante parámetros.
Mantener Azure Firewall y Azure Bastion como componentes opcionales.
Arquitectura
flowchart LR
    subgraph Office["Oficina"]
        LAN["Office LAN<br/>192.168.x.0/24"]
        OPN["OPNsense<br/>Dynamic Public IP"]
        DDNS["DDNS FQDN<br/>vpn-office.example.com"]

        LAN --> OPN
        OPN --> DDNS
    end

    Internet["Internet"]
    VPN["Azure VPN Gateway<br/>Route-Based / IKEv2"]

    subgraph Azure["Microsoft Azure"]
        subgraph Hub["Hub VNet<br/>10.100.0.0/24"]
            GatewaySubnet["GatewaySubnet"]
            Shared["SharedServicesSubnet"]
            Management["NetworkManagementSubnet"]
            FirewallSubnet["AzureFirewallSubnet"]
            BastionSubnet["AzureBastionSubnet"]
        end

        Spoke1["Apps Spoke 01<br/>10.101.0.0/24"]
        Spoke2["Apps Spoke 02<br/>10.102.0.0/24"]
        Spoke3["Shared Spoke<br/>10.103.0.0/24"]
    end

    DDNS --> Internet
    Internet -->|IPsec S2S| VPN
    VPN --> GatewaySubnet

    Hub -->|Peering + Gateway Transit| Spoke1
    Hub -->|Peering + Gateway Transit| Spoke2
    Hub -->|Peering + Gateway Transit| Spoke3
Direccionamiento IP
Redes Azure
Red	Address space
Hub VNet	10.100.0.0/24
Apps Spoke 01	10.101.0.0/24
Apps Spoke 02	10.102.0.0/24
Shared Spoke	10.103.0.0/24
Subredes del Hub
Subred	Prefijo	Uso
GatewaySubnet	10.100.0.0/27	Azure VPN Gateway
AzureBastionSubnet	10.100.0.32/26	Azure Bastion opcional
AzureFirewallSubnet	10.100.0.96/26	Azure Firewall opcional
SharedServicesSubnet	10.100.0.160/27	Servicios compartidos
NetworkManagementSubnet	10.100.0.192/27	Administración
Subredes de los Spokes
VNet	Subred	Prefijo
Apps Spoke 01	snet-apps	10.101.0.0/25
Apps Spoke 01	snet-private-endpoints	10.101.0.128/26
Apps Spoke 02	snet-apps	10.102.0.0/25
Apps Spoke 02	snet-private-endpoints	10.102.0.128/26
Shared Spoke	snet-shared	10.103.0.0/25
Shared Spoke	snet-private-endpoints	10.103.0.128/26
Restricción de direccionamiento
Azure no debe utilizar rangos que comiencen con:

192.168
Estos rangos están reservados para las oficinas.

Ejemplos válidos on-premises:

192.168.10.0/24
192.168.20.0/24
192.168.30.0/24
Topología Hub-Spoke
La Hub VNet concentra los servicios compartidos de conectividad.

El Azure VPN Gateway se despliega exclusivamente en GatewaySubnet.

Los Spokes se conectan al Hub mediante peerings bidireccionales.

Peering Hub hacia Spoke
allowVirtualNetworkAccess: true
allowForwardedTraffic: true
allowGatewayTransit: true
useRemoteGateways: false
Peering Spoke hacia Hub
allowVirtualNetworkAccess: true
allowForwardedTraffic: true
allowGatewayTransit: false
useRemoteGateways: true
Gateway Transit
Gateway Transit permite que las VNets Spoke utilicen el Azure VPN Gateway desplegado en el Hub.

Esto evita desplegar un VPN Gateway separado por cada Spoke.

La ruta esperada es:

Oficina
  → OPNsense
  → IPsec/IKEv2
  → Azure VPN Gateway
  → Hub VNet
  → VNet Peering
  → Spoke VNet
Limitación Spoke-to-Spoke
VNet Peering no proporciona tránsito automático entre dos Spokes.

El siguiente flujo no queda habilitado automáticamente:

Spoke 01
  → Hub
  → Spoke 02
Para implementar comunicación Spoke-to-Spoke debe utilizarse una de estas alternativas:

Azure Firewall.
Network Virtual Appliance.
Peerings directos controlados.
Otra solución explícita de tránsito.
Azure VPN Gateway
Configuración predeterminada:

Propiedad	Valor
Nombre	vpngw-hub-connectivity
Gateway type	VPN
VPN type	RouteBased
SKU	VpnGw1AZ
Generation	Generation2
Active-active	Deshabilitado
BGP	Deshabilitado
Public IP SKU	Standard
Public IP allocation	Static
IKE	IKEv2
El SKU y otras propiedades deben poder modificarse mediante parámetros.

Diseño para IP pública dinámica
La dirección pública de OPNsense puede cambiar cuando:

El ISP renueva la sesión.
Se reinicia el módem.
Se reinicia OPNsense.
Expira una concesión.
Cambia la infraestructura del ISP.
Azure no debe almacenar esa dirección temporal como configuración permanente.

Cada oficina debe publicar un nombre estable, por ejemplo:

vpn-office-mexico.example.com
Aunque la dirección cambie:

Antes:

vpn-office-mexico.example.com
→ 198.51.100.20

Después:

vpn-office-mexico.example.com
→ 198.51.100.95
Azure continúa utilizando:

vpn-office-mexico.example.com
Las direcciones del ejemplo pertenecen a rangos de documentación y no deben utilizarse como configuración de producción.

Local Network Gateway
Cada oficina se representa en Azure mediante un Local Network Gateway.

Una oficina dinámica debe utilizar:

fqdn: vpn-office-mexico.example.com
No debe configurarse simultáneamente:

fqdn
gatewayIpAddress
El despliegue debe seleccionar una única modalidad:

fqdn para direcciones dinámicas.
ip para direcciones estáticas.
Flujo cuando cambia la IP pública
El comportamiento esperado es:

El ISP cambia la dirección IPv4 pública.
OPNsense detecta la nueva dirección WAN.
El cliente DDNS actualiza el registro DNS.
El FQDN permanece sin cambios.
El registro DNS empieza a resolver la nueva dirección.
La asociación IKE anterior puede dejar de ser válida.
OPNsense renegocia la conexión IPsec.
Azure restaura la conectividad con la oficina.
La recuperación puede tardar debido a:

DNS TTL.
Caché DNS.
DPD.
IKE SA lifetime.
CHILD SA lifetime.
Rekey.
Resolución del FQDN.
Tiempo de actualización del proveedor DDNS.
La reconexión no debe considerarse instantánea.

Dynamic DNS en OPNsense
Requisitos
Antes de configurar DDNS se necesita:

Un proveedor DNS o DDNS.
Un hostname.
Una cuenta o API token.
Acceso administrativo a OPNsense.
Una IPv4 pública utilizable.
Instalar el plugin
En OPNsense:

System
  → Firmware
  → Plugins
Buscar:

os-ddclient
Instalar el plugin.

Crear la cuenta DDNS
Ir a:

Services
  → Dynamic DNS
  → Settings
Crear una entrada con valores similares a:

Campo	Valor
Enabled	Yes
Description	Azure VPN Office
Service	Proveedor seleccionado
Username	Si aplica
Password/API key	Token del proveedor
Zone	Dominio correspondiente
Hostname	FQDN de la oficina
Check IP method	IPv4
Interface	WAN
Force SSL	Yes
Se recomienda utilizar el backend nativo cuando el proveedor sea compatible.

Seguridad del token
El API token debería:

Modificar solamente la zona requerida.
Preferentemente modificar solamente el registro DDNS.
No conceder permisos administrativos completos.
No almacenarse en Git.
No aparecer en documentación o logs compartidos.
Validación
Desde una ubicación externa:

dig +short vpn-office-mexico.example.com
Alternativas:

host vpn-office-mexico.example.com
nslookup vpn-office-mexico.example.com
El resultado debe coincidir con la IPv4 pública del firewall.

Validación de CGNAT
Una IP dinámica sí puede utilizarse.

CGNAT puede impedir o dificultar la conexión.

Compara:

Dirección IPv4 WAN mostrada por OPNsense.
Dirección IPv4 observada desde Internet.
Si no coinciden, investiga:

CGNAT.
Double NAT.
Modem/router del ISP.
NAT upstream.
El rango:

100.64.0.0/10
se utiliza comúnmente para CGNAT.

También deben investigarse direcciones WAN privadas:

10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
Alternativas frente a CGNAT
Solicitar una IPv4 pública al ISP.
Solicitar una IPv4 estática.
Solicitar salida de CGNAT.
Configurar bridge mode.
Configurar IP passthrough.
Revisar NAT-T.
Evaluar otra solución de conectividad.
Configuración IPsec en OPNsense
Parámetros recomendados
IKE
Propiedad	Valor
Versión	IKEv2
Encryption	AES256
Integrity	SHA256
DH Group	14
Autenticación	Pre-Shared Key
ESP/IPsec
Propiedad	Valor
Encryption	AES256
Integrity	SHA256
PFS	Group 14
Mode	Tunnel
Los valores deben coincidir exactamente con la política configurada en Azure.

Crear el PSK
Ir a:

VPN
  → IPsec
  → Pre-Shared Keys
Crear una clave independiente para la oficina.

La clave debe:

Ser criptográficamente aleatoria.
Tener longitud suficiente.
Ser distinta para cada oficina.
Guardarse en Azure Key Vault cuando sea posible.
No almacenarse en este repositorio.
Crear la conexión
Ir a:

VPN
  → IPsec
  → Connections
Crear una conexión con:

Campo	Valor
Description	Azure Hub VPN
IKE version	IKEv2
Remote address	IP pública del Azure VPN Gateway
Authentication	Pre-Shared Key
Encryption	AES256
Integrity	SHA256
DH Group	14
Los nombres exactos pueden variar según la versión de OPNsense.

Redes locales
Ejemplo:

192.168.10.0/24
192.168.20.0/24
Redes remotas
10.100.0.0/24
10.101.0.0/24
10.102.0.0/24
10.103.0.0/24
DPD y reconexión
Habilitar Dead Peer Detection.

El objetivo es detectar asociaciones que hayan dejado de funcionar y permitir una nueva negociación.

También deben revisarse:

Rekey.
IKE lifetime.
CHILD SA lifetime.
NAT Traversal.
MOBIKE, según compatibilidad y diseño.
Comportamiento initiator/responder.
Reglas de firewall
Después de crear la VPN deben configurarse reglas en:

Firewall
  → Rules
  → IPsec
No debe mantenerse una regla final:

Any → Any
Ejemplo de acceso limitado:

Source:
192.168.10.0/24

Destination:
10.101.0.0/24

Protocol:
TCP

Destination port:
443
ICMP puede habilitarse temporalmente para diagnóstico.

Outbound NAT
El tráfico con destino a Azure no debe traducirse hacia la IP WAN de OPNsense.

Se deben revisar las reglas de Outbound NAT para excluir:

192.168.10.0/24 → 10.100.0.0/24
192.168.10.0/24 → 10.101.0.0/24
192.168.10.0/24 → 10.102.0.0/24
192.168.10.0/24 → 10.103.0.0/24
El tráfico debe conservar sus direcciones privadas originales.

Manejo de secretos
No deben almacenarse PSK dentro de:

Bicep.
Archivos de parámetros.
Git.
README.
Outputs.
Logs.
Historial de comandos.
Alternativa recomendada
Utilizar un Azure Key Vault existente.

Ejemplo de nombres:

vpn-office-mexico-psk
vpn-office-02-psk
Cada oficina debe utilizar una clave diferente.

Rotación
Para rotar una clave:

Crear una nueva PSK.
Actualizar el secreto de Key Vault.
Actualizar OPNsense durante una ventana controlada.
Actualizar la conexión en Azure.
Iniciar una nueva negociación.
Validar tráfico.
Revocar la clave anterior.
La rotación puede causar una interrupción breve.

Seguridad en Azure
La solución debe aplicar las siguientes medidas:

Sin RDP desde Internet.
Sin SSH desde Internet.
Sin Public IPs para las aplicaciones.
Public IP Standard para el VPN Gateway.
NSGs limitados por origen, destino y puerto.
PSK fuera del código.
Tags para identificar recursos.
Azure Firewall deshabilitado por defecto.
Azure Bastion deshabilitado por defecto.
Private Endpoints preparados.
Principio de mínimo privilegio.
Prerrequisitos
Se necesita:

Azure CLI.
Bicep CLI.
Bash.
Permisos sobre APPSEROGERVPN.
Dynamic DNS configurado.
FQDN resolviendo desde Internet.
PSK por oficina.
Azure Key Vault opcional.
OPNsense actualizado.
Red on-premises sin solapamientos con Azure.
Comprobar sesión:

az account show
Seleccionar la suscripción:

az account set \
  --subscription "55318ed6-5d8a-4bd2-889f-10e502960c28"
Comprobar el Resource Group:

az group show \
  --subscription "55318ed6-5d8a-4bd2-889f-10e502960c28" \
  --name "APPSEROGERVPN"
Permisos RBAC
Como mínimo, el operador necesita permisos para administrar recursos de red dentro del Resource Group.

Un rol como Network Contributor puede ser suficiente para los recursos de red.

Pueden requerirse permisos adicionales para:

Leer secretos de Key Vault.
Crear asignaciones de rol.
Configurar diagnósticos.
Acceder a Log Analytics.
Ejecutar Network Watcher.
Se debe aplicar el mínimo privilegio.

Configuración
Copiar el archivo de ejemplo:

cp main.parameters.example.json main.parameters.json
Editar:

main.parameters.json
Reemplazar:

FQDN de cada oficina.
Prefijos on-premises.
Región.
Tags.
Puertos.
Parámetros BGP.
Configuración de recursos opcionales.
No incluir el PSK.

Validación
Ejecutar:

chmod +x scripts/*.sh
Después:

./scripts/validate.sh
La validación debe comprobar:

Azure CLI.
Bicep.
Sesión activa.
Suscripción.
Resource Group.
Compilación.
Rangos.
Solapamientos.
FQDN.
Resolución DNS.
Placeholders.
Parámetros requeridos.
Comprobación DDNS
./scripts/check-ddns.sh \
  vpn-office-mexico.example.com
El script no debe modificar Azure ni DNS.

What-if
Antes de desplegar:

./scripts/what-if.sh
Revisar especialmente:

Recursos que serán creados.
Recursos que serían eliminados.
Cambios en VNets.
Cambios en peerings.
Cambios en VPN Gateway.
Cambios en Local Network Gateways.
Cambios en conexiones VPN.
No continuar si aparecen eliminaciones inesperadas.

Despliegue
./scripts/deploy.sh
El script debe:

Verificar la suscripción.
Verificar el Resource Group.
Ejecutar validación.
Ejecutar what-if.
Solicitar confirmación.
Obtener los secretos de forma segura.
Ejecutar el deployment.
Mostrar outputs no sensibles.
Validación posterior
Estado de conexiones
./scripts/check-vpn-status.sh
Pruebas
./scripts/test-connectivity.sh
Validar:

Resolución DDNS.
Azure VPN Gateway.
VPN Connection.
IKE SA.
CHILD SA.
Bytes enviados y recibidos.
Peerings.
Effective routes.
NSGs.
Reglas OPNsense.
Outbound NAT.
Aplicaciones.
Prueba progresiva
Realizar las pruebas en este orden:

Oficina → Hub
Oficina → Spoke
Spoke → Oficina
Aplicación → Servicio autorizado
Esto facilita identificar si el problema está en:

DDNS.
IKE.
IPsec.
Routing.
Peering.
Gateway Transit.
NSG.
Firewall.
NAT.
Sistema operativo.
Aplicación.
Monitoreo
Se recomienda supervisar:

Estado del Azure VPN Gateway.
Estado de las conexiones.
Ingress bytes.
Egress bytes.
Disponibilidad de DDNS.
Cambios en la IPv4 pública.
Logs IPsec de OPNsense.
DPD.
Rekey.
Fallos de autenticación.
Cambios en peerings.
Agregar una oficina
Para agregar una oficina:

Configurar DDNS en OPNsense.
Verificar que el FQDN resuelva.
Definir prefijos sin solapamientos.
Crear un PSK independiente.
Guardar el PSK en Key Vault.
Agregar la oficina al array offices.
Ejecutar validación.
Ejecutar what-if.
Desplegar.
Configurar IPsec en OPNsense.
Crear reglas.
Validar tráfico.
No se necesita otro Azure VPN Gateway mientras el SKU, límites y capacidad sean suficientes.

Agregar un Spoke
Para agregar un Spoke:

Seleccionar un bloque /24 no utilizado.
Agregarlo al array de Spokes.
Definir subredes.
Definir reglas NSG.
Verificar solapamientos.
Ejecutar validación.
Ejecutar what-if.
Desplegar.
Comprobar peerings.
Comprobar Gateway Transit.
BGP
BGP está deshabilitado por defecto.

Antes de habilitarlo se debe definir:

ASN de Azure.
ASN de OPNsense.
BGP peer IP de Azure.
BGP peer IP on-premises.
Rutas anunciadas.
Filtros.
Prevención de propagación no deseada.
Para el primer despliegue se recomienda validar conectividad con rutas estáticas.

Azure Firewall
Azure Firewall está deshabilitado por defecto.

Cuando se habilite:

Debe desplegarse en AzureFirewallSubnet.
Debe utilizar una Firewall Policy.
Las UDR deben usar la IP privada real del firewall.
Debe documentarse el flujo Spoke-to-Spoke.
Debe evitarse una regla excesivamente permisiva.
Debe revisarse el efecto sobre rutas anunciadas por VPN Gateway.
Azure Bastion
Azure Bastion está deshabilitado por defecto.

Cuando se habilite:

Debe usar AzureBastionSubnet.
Debe utilizar Public IP Standard.
No debe modificar GatewaySubnet.
Debe evitar la exposición directa de RDP o SSH.
Private DNS
Las zonas Private DNS son opcionales.

Ejemplos:

privatelink.azurewebsites.net
privatelink.blob.core.windows.net
privatelink.vaultcore.azure.net
Solo deben crearse las zonas necesarias para los servicios utilizados.

Troubleshooting
El FQDN no resuelve
Comprobar:

Servicio DDNS.
API token.
Hostname.
Zone.
WAN.
Método de detección de IP.
Logs de os-ddclient.
TTL.
Propagación DNS.
IKE no se establece
Comprobar:

IP pública de Azure.
PSK.
IKEv2.
AES256.
SHA256.
DH Group 14.
UDP 500.
UDP 4500.
NAT-T.
CGNAT.
Identidades IPsec.
IKE funciona pero no hay CHILD SA
Comprobar:

Redes locales.
Redes remotas.
Selectores.
ESP.
PFS14.
Lifetimes.
Address spaces en Azure Local Network Gateway.
El túnel está conectado pero no hay tráfico
Comprobar:

Reglas IPsec.
Reglas LAN.
NSGs.
UDR.
Effective routes.
Outbound NAT.
Firewall del servidor.
Gateway Transit.
Peering.
Puertos de la aplicación.
Funciona Hub pero no Spoke
Comprobar:

Peering bidireccional.
allowGatewayTransit en el Hub.
useRemoteGateways en el Spoke.
Prefijo del Spoke en OPNsense.
NSG del Spoke.
Rutas efectivas.
La VPN falla después de cambiar la IP
Comprobar:

DDNS actualizado.
Nueva dirección resuelta.
DNS TTL.
Caché DNS.
DPD.
Estado de IKE SA.
Rekey.
NAT-T.
Logs de OPNsense.
Renegociación del túnel.
Rollback
Antes de desplegar:

Guardar el resultado de what-if.
Revisar cambios destructivos.
Confirmar que no se modificarán recursos existentes ajenos a la solución.
Mantener los parámetros anteriores.
Documentar la versión desplegada.
No eliminar el Resource Group como mecanismo de rollback.

Eliminación segura
El script de eliminación debe:

Verificar la suscripción.
Mostrar recursos administrados.
Solicitar confirmación.
Exigir el nombre del Resource Group.
Eliminar recursos en orden de dependencia.
No eliminar APPSEROGERVPN.
No eliminar recursos que no pertenezcan a la solución.
Costos
Los recursos con costo pueden incluir:

Azure VPN Gateway.
Public IP.
Azure Firewall opcional.
Azure Bastion opcional.
Log Analytics.
Transferencia de datos.
Key Vault.
Network Watcher, según funcionalidad.
No se incluyen precios fijos porque dependen de:

Región.
SKU.
Horas de operación.
Transferencia.
Consumo.
Retención de logs.
Consultar Azure Pricing Calculator antes del despliegue.

Limitaciones
El cambio de IP pública puede producir una interrupción temporal.
DDNS no corrige problemas de CGNAT.
Los cachés DNS pueden retrasar la recuperación.
Spoke-to-Spoke no es transitivo automáticamente.
Los límites y rendimiento dependen del SKU del VPN Gateway.
Las pantallas de OPNsense pueden variar entre versiones.
Cambiar un Local Network Gateway de endpoint IP a FQDN puede requerir recrear las conexiones asociadas.
Una VPN por Internet no ofrece el mismo SLA o predictibilidad que un circuito privado.
Datos pendientes
Antes del despliegue deben definirse:

FQDN DDNS real por oficina.
Proveedor DDNS.
API token del proveedor.
Prefijos de oficina.
PSK independiente.
Key Vault.
Nombre de cada secreto.
Región definitiva.
Owner.
Environment.
Cost center.
Puertos autorizados.
BGP habilitado o deshabilitado.
ASN.
BGP peer IP.
Azure Firewall habilitado o deshabilitado.
Azure Bastion habilitado o deshabilitado.
Zonas Private DNS.
Hosts de prueba.
Referencias
Azure VPN Gateway.
Azure Local Network Gateway.
Azure Hub-Spoke network topology.
Azure VNet Peering y Gateway Transit.
OPNsense Dynamic DNS.
OPNsense IPsec Connections.
OPNsense IPsec Security Associations.