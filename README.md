1. Arquitectura recomendada
Tu escenario quedaría así:
Plain Text
OFICINA
192.168.x.x
|
OPNsense
|
WAN: IP pública dinámica
|
DDNS
vpn-oficina.tudominio.com
|
| IKEv2 / IPsec
|
Internet
|
Azure VPN Gateway
Public IP estática
|
GatewaySubnet
|
Hub VNet
10.100.0.0/24
|
+-------- Peering / Gateway Transit --------+
| |
Spoke Apps 01 Spoke Apps 02
10.101.0.0/24 10.102.0.0/24
El Azure VPN Gateway permanece como endpoint estable en Azure. Del lado de la oficina, el Local Network Gateway define el endpoint mediante el FQDN del DDNS. Azure documenta explícitamente que un Local Network Gateway puede representar el dispositivo on-premises mediante public IP o FQDN.
2. Antes de configurar DDNS: comprobar CGNAT
Este paso es crítico.
Una IP pública dinámica está bien para este diseño. El problema es si OPNsense está detrás de CGNAT o de otro NAT del ISP.
Paso 1. Verifica la WAN de OPNsense
En OPNsense, revisa la dirección IPv4 de WAN.
Busca algo equivalente a:
Interfaces → Overview → WAN
Supongamos:
Plain Text
WAN IPv4:
187.x.x.x
Paso 2. Compara con tu IP vista desde Internet
Comprueba tu IP pública desde la misma conexión.
Si tienes:
Plain Text
OPNsense WAN
187.150.10.25
 
Internet Public IP
187.150.10.25
es una buena señal.
Si tienes:
Plain Text
OPNsense WAN
100.72.10.15
 
Internet Public IP
187.150.10.25
probablemente existe CGNAT.
Especial atención al rango:
Plain Text
100.64.0.0/10
En ese caso, habla con tu ISP antes de continuar.
3. Configurar DDNS en OPNsense
La documentación actual de OPNsense utiliza el plugin os-ddclient para Dynamic DNS. Se instala desde plugins y posteriormente los proveedores DDNS se configuran en Services → Dynamic DNS → Settings.
Paso 1. Selecciona un nombre DNS
Por ejemplo:
Plain Text
vpn-oficina.midominio.com
No importa que cambie la IP.
Lo importante es que:
Plain Text
vpn-oficina.midominio.com
siempre apunte a la IP pública actual de OPNsense.
Por ejemplo:
Plain Text
Lunes
 
vpn-oficina.midominio.com
↓
187.150.10.25
El ISP cambia la IP:
Plain Text
Martes
 
vpn-oficina.midominio.com
↓
201.140.55.92
El FQDN permanece igual.
4. Instalar Dynamic DNS
En OPNsense:
System → Firmware → Plugins
Busca:
Plain Text
os-ddclient
e instálalo.
Es precisamente el plugin que la documentación de OPNsense indica para mantener registros DNS cuando cambia la dirección del firewall.
Después entra en:
Services → Dynamic DNS → Settings
5. Configuración general DDNS
Activa:
Plain Text
Enable: ✓
La documentación actual permite seleccionar backend ddclient o native; OPNsense recomienda probar el backend nativo cuando el proveedor utilizado sea compatible.
Yo utilizaría:
Plain Text
Backend: native
si tu proveedor está soportado.
Después crea una cuenta DDNS.
Conceptualmente:
Plain Text
Enabled: Yes
Description: Azure VPN Office
Service: <tu proveedor DNS>
Username: <si aplica>
Password/API Key: <token>
Zone: midominio.com
Hostname: vpn-oficina.midominio.com
Check IP method: IPv4
Interface: WAN
Force SSL: Yes
Los campos exactos dependen del proveedor. OPNsense admite autenticación mediante usuario/password o token/API key según el servicio.
Seguridad
Siempre que tu proveedor lo permita, utiliza un API token limitado exclusivamente a modificar ese registro DNS, en lugar de una contraseña con privilegios sobre toda tu zona.
6. Validar DDNS antes de tocar Azure
Desde otra computadora:
Shell
nslookup vpn-oficina.midominio.com
o:
Shell
dig +short vpn-oficina.midominio.com
Deberías obtener:
Plain Text
187.150.10.25
Compara ese resultado con la WAN pública actual.
Deben corresponder.
7. Configurar Azure para utilizar el FQDN
Aquí está el cambio fundamental respecto al diseño original.
En Bicep tu Local Network Gateway debe utilizar el FQDN, no guardar como endpoint la IP temporal que tenga OPNsense en ese momento.
Conceptualmente:
Bicep
resource localNetworkGateway 'Microsoft.Network/localNetworkGateways@...' = {
name: 'lng-office-opnsense'
location: location
 
properties: {
fqdn: opnsenseFqdn
 
localNetworkAddressSpace: {
addressPrefixes: officeAddressPrefixes
}
}
}
y:
Plain Text
opnsenseFqdn =
vpn-oficina.midominio.com
Tu red Azure podría ser:
Ubicación	CIDRHub	10.100.0.0/24
Apps01	10.101.0.0/24
Apps02	10.102.0.0/24
Shared	10.103.0.0/24
Oficina	192.168.x.x/24
Así se respeta tu requisito de no utilizar 192.168.x.x en Azure, pero puedes continuar utilizándolo en tus oficinas.
8. Compatibilidad IPsec
Azure VPN Gateway soporta VPN Site-to-Site mediante IPsec/IKE, y los gateways route-based actuales soportan IKEv2.
Para este escenario utilizaría:
Plain Text
VPN:
 
Site-to-Site
Route Based
IKEv2
PSK
No empezaría habilitando BGP. Primero levantaría correctamente la VPN S2S con rutas estáticas y posteriormente evaluaría BGP si realmente lo necesitas.
9. Obtener el endpoint Azure
Una vez desplegado el Azure VPN Gateway necesitarás su IP pública.
Por ejemplo:
Plain Text
20.x.x.x
Esta será la Remote Address/Gateway de OPNsense.
Observa la asimetría:
Plain Text
Azure conoce OPNsense por:
vpn-oficina.midominio.com
 
OPNsense conoce Azure por:
20.x.x.x
Eso está bien.
10. Configurar IPsec en OPNsense
Las versiones actuales de OPNsense gestionan IPsec mediante Connections basadas en swanctl.conf/strongSwan. La terminología difiere de las antiguas pantallas Phase 1/Phase 2, aunque conceptualmente siguen existiendo el establecimiento IKE y las CHILD SAs.
Accede a:
VPN → IPsec → Connections
Y habilita IPsec.
11. Crear el Pre-Shared Key
Ve a:
VPN → IPsec → Pre-Shared Keys
La documentación recomienda definir específicamente las identidades cuando sea posible para evitar que una misma PSK resulte aplicable innecesariamente a varias conexiones.
Genera una PSK criptográficamente fuerte.
Por ejemplo:
Plain Text
32+ caracteres aleatorios
 
No utilices ejemplos como:
Plain Text
Azure123
myvpnpassword
empresa2026
La PSK introducida en OPNsense debe ser exactamente la misma que configures en la conexión de Azure.
12. Crear la conexión IKE
En:
VPN → IPsec → Connections
crea una nueva conexión.
Conceptualmente:
Plain Text
Description:
Azure-Hub-VPN
 
Version:
IKEv2
 
Remote address:
<IP pública de Azure VPN Gateway>
Para el endpoint local procura no fijar como identidad la IP WAN dinámica si no es necesario.
Tu WAN puede cambiar.
13. Parámetros criptográficos
Si aplicas la política personalizada que definimos en tu arquitectura de Azure, mantén idénticas las propuestas a ambos lados.
Base inicial:
IKE
Plain Text
IKE Version: IKEv2
 
Encryption: AES-256
Integrity: SHA-256
DH Group: 14
ESP/IPsec
Plain Text
Encryption: AES-256
Integrity: SHA-256
PFS: Group 14
Antes del despliegue definitivo, haz que tu Bicep utilice exactamente estos mismos algoritmos en la ipsecPolicy. No permitas que Copilot invente los nombres de las enumeraciones de Azure.
14. Configurar las redes
Supongamos que la oficina utiliza:
Plain Text
192.168.10.0/24
 
Y Azure:
Plain Text
10.100.0.0/24
10.101.0.0/24
10.102.0.0/24
10.103.0.0/24
En el CHILD SA/Phase 2 conceptualmente tendrás:
Plain Text
Local:
 
192.168.10.0/24
Remote:
Plain Text
10.100.0.0/24
10.101.0.0/24
10.102.0.0/24
10.103.0.0/24
La documentación de OPNsense muestra este mismo concepto: en una conexión IPsec policy-based se definen las redes Local y Remote que generan las políticas del túnel.
15. Firewall de OPNsense
No basta con levantar el túnel.
También necesitas permitir el tráfico.
Revisa:
Firewall → Rules → IPsec
La documentación de OPNsense indica que, una vez levantado el túnel, deben añadirse las políticas de firewall necesarias para aceptar tráfico a través de IPsec.
No recomiendo empezar con:
Plain Text
Allow any → any
Permite únicamente tus redes y servicios.
Por ejemplo:
Plain Text
Source:
192.168.10.0/24
 
Destination:
10.101.0.0/24
 
TCP:
443
Después amplías según las necesidades reales de las aplicaciones.
16. NAT
Asegúrate de que:
Plain Text
192.168.x.x → 10.x.x.x
no se NATee hacia la IP WAN.
El tráfico VPN debe conservar sus direcciones privadas en este escenario.
Comprueba tus reglas de Outbound NAT y crea las excepciones correspondientes si tu configuración lo requiere.
17. Levantar la VPN
En OPNsense revisa:
VPN → IPsec → Status Overview
Las versiones actuales también disponen de Security Association Database y Security Policy Database, útiles para diagnosticar IPsec.
Debes validar primero:
Plain Text
IKE SA: ESTABLISHED
y después las asociaciones CHILD/IPsec.
18. Comprobar Azure
En Azure:
Shell
az network vpn-connection show \
--resource-group APPSEROGERVPN \
--name conn-hub-to-office-opnsense
Y puedes consultar el estado de la conexión.
El objetivo final es:
Plain Text
connectionStatus:
Connected
19. Probar tráfico real
Haz las pruebas progresivamente.
Primero:
Plain Text
Oficina
↓
Hub
Después:
Plain Text
Oficina
↓
Hub
↓
Spoke
Por ejemplo:
Plain Text
192.168.10.100
↓
10.101.0.10
Esto permite diferenciar problemas de:
IKE/IPsec
routing
VNet Peering
Gateway Transit
NSG
firewall OPNsense
firewall del servidor
20. ¿Qué sucede cuando cambia la IP?
Este es el caso realmente interesante.
Imagina:
Plain Text
10:00
 
OPNsense:
187.150.10.25
 
DNS:
vpn-oficina.midominio.com
→ 187.150.10.25
El ISP reinicia el enlace.
Ahora:
Plain Text
10:15
 
OPNsense:
187.150.44.91
DDNS detecta el cambio y actualiza:
Plain Text
vpn-oficina.midominio.com
→ 187.150.44.91
El plugin DDNS de OPNsense está diseñado precisamente para actualizar el registro DNS cuando cambia la dirección del firewall.
La asociación IPsec anterior dejará de ser válida y se necesitará una nueva negociación.
Por eso recomiendo configurar correctamente:
DPD
reconexión/rekey
DDNS frecuente
TTL DNS razonablemente corto
OPNsense como iniciador capaz de restablecer el túnel
No asumiría failover instantáneo cuando cambia la IP.
21. Una limitación importante
Microsoft Learn advierte de otra característica relevante: no puedes convertir directamente un Local Network Gateway existente entre endpoint IP y endpoint FQDN. Para cambiar el tipo, hay que eliminar las conexiones asociadas, crear nuevamente el Local Network Gateway con el nuevo tipo de endpoint y recrear las conexiones. Por ello, si sabes que tu dirección es dinámica, conviene implementar FQDN desde el primer despliegue.
Esto refuerza mi recomendación de modificar ahora el Bicep, antes del deployment.
22. Diseño que recomiendo finalmente
Para tu suscripción:
Plain Text
55318ed6-5d8a-4bd2-889f-10e502960c28
y:
Plain Text
APPSEROGERVPN
dejaría el modelo así:
Plain Text
┌ Office 01
│ OPNsense
│ Dynamic IP
│ DDNS
│ vpn-office01.domain
│
│ IPsec/IKEv2
│
Azure VPN Gateway
│
HUB /24
10.100.0.0
│
┌──────────┼──────────┐
│ │ │
Peering Peering Peering
│ │ │
10.101.0.0 10.102.0.0 10.103.0.0
/24 /24 /24
Y para una segunda oficina:
Plain Text
Office 02
OPNsense
Dynamic IP
↓
vpn-office02.domain
↓
Local Network Gateway #2
↓
VPN Connection #2
↓
MISMO Azure VPN Gateway
Azure VPN Gateway permite múltiples conexiones hacia un mismo gateway, compartiendo entre ellas la capacidad disponible del gateway.
Veredicto
Sí recomiendo continuar con el diseño FQDN/DDNS. Está alineado con el modelo soportado de Azure VPN Gateway, donde el Local Network Gateway puede representar el dispositivo on-premises mediante IP pública o FQDN.
Antes de desplegarlo, validaría estas cuatro cosas:
OPNsense tiene salida mediante una IPv4 pública utilizable y no CGNAT problemático.
El DDNS resuelve correctamente desde Internet.
Azure se crea con fqdn, no tomando la IP dinámica actual como gatewayIpAddress.
Las propuestas IKE/IPsec de Azure y OPNsense coinciden exactamente.
