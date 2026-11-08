# CamRemote

Controla la cámara del iPhone desde el Mac, sin cables.

- **CamRemoteCam** (iPhone): hace de cámara. Se anuncia en la red y graba en Fotos.
- **CamRemoteMac** (Mac): ve la vista previa en directo y controla todo.

## Qué controla
- Grabar / parar (botón o ⌘R) con contador, batería y espacio libre del iPhone.
- Lente: gran angular 0,5×, principal 1×, teleobjetivo y frontal (según el modelo).
- Formato: 720p / 1080p / 4K, 24–240 fps (lo que admita cada lente), horizontal o vertical, HEVC o H.264, estabilización.
- Zoom, enfoque (auto/manual), exposición (auto/manual con ISO y obturación, compensación EV), balance de blancos (auto/Kelvin) y linterna.

## Conexión
Bonjour (`_camremote._tcp`) sobre TCP con peer-to-peer activado: funciona en la misma Wi-Fi
y también directo entre iPhone y Mac (Wi-Fi y Bluetooth encendidos, sin red común).
La primera vez el Mac pide el **PIN de 4 cifras** que sale en la pantalla del iPhone; luego se conecta solo.

## Compilar
```bash
xcodegen generate
open CamRemote.xcodeproj
```
- Esquema **CamRemoteCam** → elige tu iPhone → Run.
- Esquema **CamRemoteMac** → My Mac → Run.

Acepta en ambos el permiso de **red local** (y en el iPhone cámara, micrófono y Fotos).
La app del iPhone debe estar en primer plano mientras graba (iOS no permite usar la cámara en segundo plano);
la pantalla no se bloquea sola mientras está abierta.
