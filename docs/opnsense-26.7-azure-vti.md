# OPNsense 26.7: VPN Site-to-Site con Azure mediante VTI

## 1. Alcance y estado de partida

Guía para la versión **OPNsense 26.7.6_3-amd64**, indicada en la captura del operador, usando **VPN > IPsec > Connections**, no la interfaz heredada Phase 1 / Phase 2. Los nombres de campos se basan en la documentación oficial y los formularios públicos actuales de OPNsense; no se han comprobado todos los campos en esa compilación exacta.

**Este procedimiento está documentado, no aplicado ni probado en el firewall.** La infraestructura Azure terminó correctamente. En la última consulta de esta sesión, la conexión creada manualmente tenía aprovisionamiento `Succeeded`, estado `NotConnected`, política **Default** (`ipsecPolicies: []`), IKEv2, BGP deshabilitado y DPD timeout de 45 segundos. No confundir aprovisionamiento correcto con túnel operativo.

Esta configuración no necesita Key Vault. Mantener `manageConnections=false` en los parámetros locales para que Bicep no administre la conexión manual.

### Datos de esta instalación

| Elemento | Valor |
|---|---|
| Suscripción | `55318ed6-5d8a-4bd2-889f-10e502960c28` |
| Resource Group | `APPSEROGERVPN` |
| VPN Gateway Azure | `roger-vpn-vpn-gateway`, route-based, `VpnGw1AZ` |
| IP pública del gateway Azure | `158.23.21.92` |
| Conexión Azure | `roger-vpn-office-01-connection` |
| Local Network Gateway | `roger-vpn-office-01-lng` |
| DDNS de oficina en el LNG | `azure.jaropro.net` |
| LAN autorizada en el LNG | `192.168.50.0/24` |
| OPNsense LAN | `192.168.50.254/24` |
| OPNsense WAN | `192.168.5.3/29` |
| Gateway WAN / ER605 | `192.168.5.1` |
| Hub Azure | `10.100.0.0/24` |
| Spoke apps-01 | `10.101.0.0/24` |
| Spoke apps-02 | `10.102.0.0/24` |

No anunciar ni enrutar hacia Azure las redes de los ISP `192.168.4.0/24`, `192.168.44.0/24` ni el tránsito `192.168.5.0/29`. No sustituir la LAN por `192.168.0.0/16`.

## 2. Preparación y seguridad

1. Reservar una ventana de mantenimiento y disponer de acceso local/consola al firewall.
2. Exportar un respaldo desde **System > Configuration > Backups**. Guardarlo de forma privada: puede contener secretos. Registrar las rutas, reglas y NAT anteriores.
3. No modificar DHCP, la LAN, el gateway WAN ni la ruta por defecto de Internet. No habilitar BGP para seguir esta guía.
4. Revisar que no haya otra conexión IPsec heredada o moderna para el mismo peer/prefijos. No dejar configuraciones duplicadas activas.
5. **Reemplazar la PSK que apareció en una captura anterior.** Considerarla expuesta. Generar una nueva PSK aleatoria de alta entropía y guardarla solamente en el gestor privado del operador, Azure Portal y OPNsense. No copiarla al repositorio, chat, comandos, logs ni nuevas capturas.
6. Verificar que `azure.jaropro.net`, consultado con un resolvedor público, apunta a la IPv4 pública del ISP activo. No debe resolver a `192.168.5.3` ni a la IP Azure.

Ejemplo de consulta desde Windows, sin secretos:

```powershell
Resolve-DnsName azure.jaropro.net -Type A -Server 1.1.1.1
```

La IPv4 pública de oficina observada anteriormente fue `189.236.75.52`; **no asumir que sigue vigente**. Compararla con la salida pública real del ISP activo antes de configurar las identidades del apartado 5.

## 3. Primero: alinear la conexión Azure

En Azure Portal, abrir **APPSEROGERVPN > roger-vpn-office-01-connection > Configuration**. Programar la interrupción si hubiera un túnel activo.

1. Confirmar que usa `roger-vpn-vpn-gateway` y `roger-vpn-office-01-lng`.
2. Mantener IKEv2, BGP deshabilitado y **Use policy based traffic selectors = Disabled**.
3. Cambiar **IPsec / IKE policy** de **Default** a **Custom** y guardar:

| Campo Azure | Valor |
|---|---|
| IKE encryption | `AES256` |
| IKE integrity | `SHA256` |
| DH group | `DHGroup14` |
| IPsec encryption | `AES256` |
| IPsec integrity | `SHA256` |
| PFS group | `PFS14` |
| IPsec SA lifetime | `27000` segundos |
| IPsec SA maximum size | `102400000` KB |
| DPD timeout | Conservar `45` segundos |
| Connection mode | `Default` |

4. En **Shared key**, introducir la nueva PSK. Se utilizará exactamente la misma en OPNsense.
5. Confirmar en el LNG que el endpoint sigue siendo el FQDN `azure.jaropro.net` y el espacio de direcciones es únicamente `192.168.50.0/24`.

Estos algoritmos coinciden con el [módulo de referencia](../modules/vpn-connection.bicep). Cambiar el módulo no actualiza la conexión mientras `manageConnections=false`. No continuar suponiendo que la política Default ya equivale a esta política Custom.

## 4. Crear la Virtual Tunnel Interface

En **VPN > IPsec > Virtual Tunnel Interfaces**, agregar:

| Campo | Valor |
|---|---|
| Enabled | Activado |
| Name / descripción | `AZURE_VTI` |
| Reqid | `10`, solo si no está usado por otra VTI |
| Local address | `192.168.5.3` |
| Remote address | `158.23.21.92` |
| Tunnel local address | `169.254.100.1` |
| Tunnel remote address | `169.254.100.2` |
| Skip firewall rules | Dejar desactivado; no se requiere source NAT |

Guardar/aplicar. Si `Reqid=10` está ocupado, elegir otro valor libre y usarlo también en el CHILD.

Las direcciones **Local/Remote address** son los extremos exteriores: OPNsense se enlaza a su WAN privada, y ER605/módem hacen NAT hacia Internet. No poner la IPv4 pública del ISP como dirección local de una interfaz que no la tiene asignada.

Las direcciones **Tunnel local/remote** son una propuesta de direccionamiento interno punto a punto para el enrutamiento local. Comprobar antes que no se usen en otra VPN/BGP. No son direcciones de una VM ni direcciones configuradas en Azure; con BGP deshabilitado no se asignará `169.254.100.2` al gateway Azure. Por tanto, **no esperar respuesta a ping de esa dirección ni usarla para monitorizar disponibilidad**. La verificación válida será tráfico a un host Azure real.

La documentación oficial de VTI usa dos equipos OPNsense. Aquí se adapta ese mecanismo de rutas al peer administrado Azure; esta adaptación requiere las pruebas del apartado 10 antes de declararse operativa.

## 5. Crear IKEv2 y sus autenticaciones

En **VPN > IPsec > Connections**, habilitar IPsec y agregar una conexión:

| Campo | Valor |
|---|---|
| Enabled | Activado |
| Description | `AZURE_S2S` |
| Version | IKEv2 |
| Local addresses | `192.168.5.3` |
| Remote addresses | `158.23.21.92` |
| Proposals | AES256 + SHA256 + MODP2048 / DH14 |
| Unique, avanzado | `Replace` |
| Rekey time (s) | `14400`, propuesta de rekey local IKE |
| DPD delay (s) | `30` |

La propuesta strongSwan equivalente es `aes256-sha256-modp2048`. Si la pantalla ofrece componentes, seleccionar esos componentes; no pegar la cadena en un campo que solo acepta opciones. No confundir AES-CBC con AES-GCM ni DH14 con un grupo elíptico.

`Rekey time` es un temporizador local de renovación, no una exigencia de igualdad con la duración de SA del peer. `DPD delay` es el intervalo de sondeo; **no equivale** al timeout Azure de 45 segundos. No configurar el campo obsoleto `DPD timeout` como si controlara IKEv2.

### Identidad no es dirección de enlace

En las tablas siguientes, `IP_PUBLICA_OFICINA_ACTUAL` significa la IPv4 pública verificada en el apartado 2, no el texto literal. Se propone como identidad inicial de interoperabilidad. Debe validarse con los IDs efectivamente enviados/aceptados en los logs IKE; no se ha observado todavía una autenticación exitosa en este equipo.

En la cuadrícula **Local Authentication**:

| Campo | Valor |
|---|---|
| Authentication | `Pre-Shared Key` |
| Id | `IP_PUBLICA_OFICINA_ACTUAL` |

En **Remote Authentication**:

| Campo | Valor |
|---|---|
| Authentication | `Pre-Shared Key` |
| Id | `158.23.21.92` |

En **VPN > IPsec > Pre-Shared Keys**, agregar:

| Campo | Valor |
|---|---|
| Local Identifier | La misma `IP_PUBLICA_OFICINA_ACTUAL` usada en Local Authentication |
| Remote Identifier | `158.23.21.92`, igual que Remote Authentication |
| Type | PSK |
| Pre-Shared Key | La nueva PSK introducida en Azure, sin mostrarla |
| Description | `AZURE_S2S_PSK` |

El FQDN del LNG sirve para **descubrir el endpoint**, no configura automáticamente la identidad IKE. No dar por hecho que `azure.jaropro.net` funciona como ID de autenticación solo porque resuelve. Tampoco sustituir el ID remoto por `%any` para ocultar un error: comprobar el ID recibido y la selección de PSK en los logs.

**Límite del failover:** si cambia la IPv4 pública y se usa como ID local, actualizar ese ID tanto en Local Authentication como en Local Identifier de la PSK. DDNS no actualiza esos campos. Una identidad estable alternativa requiere comprobar su aceptación con Azure; no se promete failover desatendido con esta identidad inicial.

## 6. Crear el CHILD de la VTI

En **Children** de `AZURE_S2S`, agregar:

| Campo | Valor |
|---|---|
| Enabled | Activado |
| Description | `AZURE_VTI_CHILD` |
| Connection | `AZURE_S2S` |
| Mode | `Tunnel` |
| Policies | **Desactivado** |
| Reqid | `10`, exactamente el mismo de la VTI |
| ESP proposals | AES256 + SHA256 + MODP2048 / PFS14 |
| Local | `0.0.0.0/0` |
| Remote | `0.0.0.0/0` |
| Start action | `Start` |
| DPD action | `Restart` |
| Rekey time (s) | `24000`, menor que la duración Azure de `27000` |

La propuesta ESP equivalente es `aes256-sha256-modp2048`: el grupo incluye PFS14. La primera negociación de un CHILD no basta para probar que su rekey con PFS funcionará; comprobar también una renovación posterior.

La duración de SA Azure y el `Rekey time` local son conceptos distintos. El límite Azure en KB tampoco debe copiarse a un campo OPNsense medido en bytes o segundos. Conservar los demás campos avanzados salvo necesidad documentada.

> **Evitar pérdida de acceso:** en VTI los selectores `0.0.0.0/0` permiten transportar los prefijos que las rutas elijan; **no son una ruta por defecto ni una regla de permiso**. Mantener **Policies desactivado** antes de aplicar. Instalar políticas amplias por error puede capturar tráfico ajeno a la VPN y bloquear la administración del firewall.

El ejemplo oficial usa `Trap`; aquí se elige `Start` para iniciar activamente desde la oficina detrás de NAT. No mezclar esta configuración VTI con selectores restrictivos de una configuración policy-based sin rediseñar ambos extremos.

Guardar y aplicar en Connections. Revisar que no haya errores de validación y que IPsec esté habilitado.

## 7. Interfaz asignada, gateway y rutas

1. En **Interfaces > Assignments**, identificar la interfaz creada por la VTI, normalmente `ipsec10`. Si necesita asignación, asignarla como `AZURE_VTI` y habilitarla. No confundirla con el grupo IPsec de filtrado.
2. Mantener la dirección del túnel gestionada por la VTI; no añadir otro cliente DHCP ni una dirección estática duplicada desde la interfaz asignada. Dejar los tipos de configuración IPv4/IPv6 en `None` cuando los muestre esa pantalla.
3. No activar **Block private networks** ni **Block bogon networks** en la interfaz de túnel. Conservar inicialmente MTU/MSS predeterminados.
4. En **System > Gateways > Configuration**, crear:

| Campo | Valor |
|---|---|
| Name | `AZURE_VTI_GW` |
| Interface | La VTI `ipsec10` / `AZURE_VTI` |
| Address Family | IPv4 |
| IP address | `169.254.100.2` |
| Upstream Gateway | **Desactivado**; no convertir en gateway por defecto |
| Disable Gateway Monitoring | **Activado** |

No utilizar este gateway en grupos de failover WAN ni crear una ruta por defecto a través de él.

En **System > Routes > Configuration**, agregar únicamente:

| Network Address | Gateway |
|---|---|
| `10.100.0.0/24` | `AZURE_VTI_GW` |
| `10.101.0.0/24` | `AZURE_VTI_GW` |
| `10.102.0.0/24` | `AZURE_VTI_GW` |

Guardar/aplicar. En **System > Routes > Status**, comprobar que esos destinos salen por la VTI y que la ruta `0.0.0.0/0`, así como el endpoint público `158.23.21.92`, siguen saliendo por WAN vía `192.168.5.1`.

## 8. Firewall y NAT

### LAN hacia Azure

Crear un alias de redes `AZURE_PRIVATE_NETS` con los tres `/24` Azure. En **Firewall > Rules > LAN**, permitir desde los hosts/subredes LAN autorizados hacia los destinos y puertos Azure aprobados.

- Colocar la regla por encima de reglas genéricas de policy routing multi-WAN.
- Dejar **Gateway = default** en esa regla: usar la tabla de rutas, no forzar el gateway/grupo WAN ni fijar un nuevo default route.
- Limitar protocolo, destinos y puertos al servicio requerido; habilitar logging durante la validación.
- Revisar también reglas floating y estados existentes si todavía fuerzan salida WAN. No borrar todos los estados indiscriminadamente; una limpieza selectiva interrumpe esos flujos.

### Azure hacia LAN

Con el filtrado OPNsense predeterminado, el tráfico descifrado entra por el grupo **Firewall > Rules > IPsec** (`enc0`). Crear allí las reglas de entrada necesarias desde hosts/redes Azure aprobados hacia hosts y puertos LAN autorizados. Los retornos de conexiones ya permitidas usan el estado; una regla nueva es necesaria para nuevas conexiones iniciadas desde Azure.

No confiar únicamente en reglas colocadas en la interfaz VTI asignada. Esta guía **no cambia tunables de filtrado IPsec**. Si ya se alteraron, revisar el modelo de filtrado antes de aplicar las reglas. No dejar un permiso permanente `Any -> Any`.

### Outbound NAT

En **Firewall > NAT > Outbound**, conservar el NAT normal de salida a Internet.

- LAN hacia los tres prefijos Azure debe conservar origen `192.168.50.x`, no traducirse a WAN ni a `169.254.100.1`.
- Si las reglas existentes solo hacen NAT en WAN, normalmente no hace falta agregar ninguna regla para la VTI.
- Si hay reglas híbridas/manuales que también coinciden con la VTI o esos flujos, ajustarlas de forma específica para evitar esa traducción. No pasar todo el firewall a modo manual ni desactivar todo Outbound NAT por esta VPN.
- Confirmar el origen con una captura y con la vista del host Azure, no solo leyendo la configuración.

Opcionalmente, para impedir que los destinos privados Azure salgan en claro por WAN si se retiran las rutas VTI, agregar una regla floating **Block / Quick / Out**, interfaz WAN, destino `AZURE_PRIVATE_NETS`, y validarla. No bloquear el endpoint público Azure ni UDP 500/4500. Este control no sustituye las rutas y reglas anteriores.

### ER605, módem y NAT-T

OPNsense está detrás de ER605 y del módem del ISP activo. Permitir salida y retorno UDP **500/4500** hacia `158.23.21.92`. Comprobar NAT-T en las asociaciones/logs; no desactivarlo ni obligar a IPsec a evitar NAT.

Al iniciar desde OPNsense, primero probar el estado NAT de salida. Si se requiere inicio desde Azure, revisar reenvíos UDP 500/4500 en cada NAT hasta `192.168.5.3`, restringidos al peer Azure y sin otro terminador IPsec usando esos puertos. Con NAT-T no asumir que sea necesario reenviar ESP por separado. No exponer GUI/SSH ni habilitar una DMZ general como solución.

Un reenvío local no elimina CGNAT del proveedor. Si no hay negociación estable, verificar el direccionamiento público de cada ISP y solicitar una opción compatible; no prometer que el comportamiento será idéntico en ambos enlaces.

## 9. Verificación de Azure y rutas de retorno

- LNG: solo `192.168.50.0/24`, endpoint DDNS vigente.
- Conexión: IKEv2, Custom conforme al apartado 3, BGP y policy-based selectors deshabilitados.
- Hub hacia cada Spoke: peering `Connected`, `allowGatewayTransit=true`.
- Spoke hacia Hub: `Connected`, `useRemoteGateways=true`.
- En la NIC de cada host Azure de prueba, comprobar ruta efectiva de retorno a `192.168.50.0/24` por Virtual Network Gateway; revisar UDR y propagación si no aparece.
- NSG y firewall del host deben permitir el flujo desde la IP LAN real y su puerto. Los NSG desplegados no implican permiso para todos los servicios.
- No poner NSG ni UDR en `GatewaySubnet` para intentar corregir el túnel.

El despliegue no creó VMs ni servicios de prueba. Elegir un host existente o aprovisionar uno mediante un cambio separado antes de validar tráfico de aplicación.

## 10. Pruebas y criterio de aceptación

1. En **VPN > IPsec > Status Overview**, verificar IKE SA establecida y CHILD SA instalada, con el Reqid y algoritmos esperados. En Azure, confirmar `Connected`.
2. Desde un **equipo LAN real**, probar un servicio que esté escuchando en un host Azure real. Sustituir el destino del ejemplo:

   ```powershell
   Test-NetConnection -ComputerName <IP_PRIVADA_REAL_HOST_AZURE> -Port <PUERTO_AUTORIZADO>
   ```

3. Repetir para hosts aprobados del Hub y de cada Spoke donde haya un servicio. No usar una dirección de `GatewaySubnet` como host de prueba.
4. Verificar que aumenten los contadores de bytes en ambos sentidos. Si se prueba desde el propio firewall, elegir explícitamente una dirección origen LAN cuando la herramienta lo permita; el origen VTI `169.254.100.1` no pertenece al prefijo del LNG y no sustituye una prueba desde la LAN.
5. Desde un host Azure, probar un servicio LAN autorizado, con ruta de retorno, regla IPsec y firewall del host correctos.
6. Comprobar que DNS e Internet siguen funcionando desde LAN y que solo los tres prefijos Azure usan el túnel.
7. Observar un rekey del CHILD y recuperación tras una desconexión controlada. Probar failover ISP solo en ventana aprobada, verificando DDNS y actualización del ID local si cambia la IP pública.

No probar la VPN con ping a `158.23.21.92` ni a `169.254.100.2`: ninguno demuestra conectividad de aplicación. ICMP a un host real requiere autorización específica.

### Lista de aceptación

- [ ] PSK anterior reemplazada en ambos extremos, sin valor registrado en la documentación.
- [ ] Política Azure Custom y propuestas OPNsense verificadas.
- [ ] IKE/CHILD activas y Azure `Connected`.
- [ ] Rutas Azure por VTI; ruta por defecto y endpoint público por WAN.
- [ ] Tráfico aprobado bidireccional a hosts reales, contadores crecientes y origen LAN sin NAT.
- [ ] Internet, DHCP y LAN sin cambios no previstos.
- [ ] Rekey y recuperación comprobados; límites de failover documentados.
- [ ] Respaldo y procedimiento de reversión disponibles.

## 11. Diagnóstico

Consultar **VPN > IPsec > Log File**, Status Overview, rutas, estados y logs de firewall. Para capturas usar **Interfaces > Diagnostics > Packet Capture**, filtrando WAN por peer y UDP 500/4500, y el tráfico interior por hosts/puertos de prueba. No compartir capturas o exports sin revisar su contenido.

| Síntoma | Comprobación |
|---|---|
| No sale IKE | IPsec habilitado, Start action, endpoint, ruta WAN, reglas de salida y ausencia de conexión duplicada |
| Sale IKE, no vuelve | ER605/módem, NAT-T, ISP/CGNAT, DDNS y tráfico de retorno UDP 500/4500 |
| `NO_PROPOSAL_CHOSEN` | IKE AES256/SHA256/DH14; ESP AES256/SHA256/PFS14; Azure Custom realmente guardada |
| `AUTHENTICATION_FAILED` | PSK nueva idéntica, IDs enviados/recibidos y selección de la entrada PSK; no debilitar a `%any` |
| `TS_UNACCEPTABLE` | CHILD VTI con Policies desactivado y selectores amplios; policy-based selectors Azure deshabilitado |
| IKE activa, CHILD ausente | ESP/PFS, Reqid, negociación en logs y ausencia de configuraciones heredadas en conflicto |
| CHILD activa, contadores a cero | Rutas VTI y policy routing LAN; probar desde LAN real hacia servicio existente |
| Bytes solo en un sentido | Ruta de retorno Azure, LNG, NSG, regla IPsec, firewall del host y ausencia de source NAT |
| Hub funciona, Spoke no | Tránsito de gateway en ambos peerings, rutas efectivas y NSG del Spoke |
| Gateway local parece siempre disponible | Monitorización deshabilitada por diseño; consultar SA, estado Azure y servicio real |
| Falla tras cambio de ISP | DDNS, IP pública/ID local, estado NAT anterior, DPD y nueva negociación; failover no instantáneo |
| Conecta pero falla tráfico grande | Captura, MTU del camino y fragmentación; ajustar MTU/MSS solo después de medir |

## 12. Reversión

1. Usar consola/acceso local si se pierde administración. Si se activó Policies accidentalmente con selectores amplios, deshabilitar ese CHILD/conexión o restaurar el respaldo.
2. Deshabilitar `AZURE_S2S` y aplicar; retirar/deshabilitar las tres rutas estáticas nuevas y el gateway VTI cuando ya no haya dependencias.
3. Revertir únicamente las reglas LAN/IPsec/floating y cambios NAT agregados por este procedimiento; conservar reglas anteriores.
4. Retirar la asignación/VTI si ya no tiene referencias. Restaurar el respaldo privado si es necesario y verificar LAN, DHCP, DNS e Internet.
5. No borrar el Resource Group, gateway, VNets, peerings ni Key Vault como rollback del firewall. Mantener presente que el VPN Gateway sigue generando costo aunque no haya túnel.
6. Si se revierte la política Azure, registrar el cambio y detener las pruebas hasta volver a alinear los extremos. No reutilizar la PSK expuesta como rollback.

## 13. Referencias

- [OPNsense: Route based (VTI) PSK setup con Connections](https://docs.opnsense.org/manual/how-tos/ipsec-s2s-conn-route.html).
- [OPNsense: IPsec, VTI y consideraciones de filtrado](https://docs.opnsense.org/manual/vpnet.html).
- [OPNsense: formulario público de VTI](https://github.com/opnsense/core/blob/master/src/opnsense/mvc/app/controllers/OPNsense/IPsec/forms/dialogVTI.xml), referencia de campos actual, no fijada a la compilación instalada.
- [Microsoft: dispositivos VPN y parámetros de interoperabilidad](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-devices).
- [Microsoft: políticas IPsec/IKE personalizadas](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-ipsecikepolicy-rm-powershell).
- [README de la solución](../README.md#10-configuración-ipsec).
