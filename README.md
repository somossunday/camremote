# CamRemote

Apps propias para grabar con el iPhone controlado desde el Mac y etalonar luego los vídeos. No se publican en la App Store.

| Carpeta | Apps | Qué hace |
|---|---|---|
| [`iphone-cam-remote/`](iphone-cam-remote/) | **CamRemote** (iPhone), **CamRemote** (Mac) y **CamRemote Helper** (Mac, invisible) | El iPhone hace de cámara y el Mac lo controla por Wi‑Fi. Las dos apps comparten el protocolo de `Shared/` y salen del mismo `project.yml`, así que van siempre juntas. |
| [`iphone-cam-remote-editor/`](iphone-cam-remote-editor/) | **CamRemote Color** (Mac) | Editor de color, LUTs y ProRes para los vídeos grabados. No comparte código con las otras. |

## Requisitos
- Xcode 26 y [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Para CamRemote Color, el Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`.
- Equipo de firma `Z8GY99W9QQ`; bundle ids `com.adrianmillares.camremote.(camera|mac|editor)`.

## Generar y compilar
Los `.xcodeproj` no se suben al repositorio porque se generan a partir de `project.yml`:

```bash
cd iphone-cam-remote && xcodegen generate
cd iphone-cam-remote-editor && xcodegen generate
```

Más detalles en el README de cada carpeta.

## Iconos
Diseñados con la API de imágenes de OpenAI (familia «rojo plano»). En `iphone-cam-remote/design/icons/` están las propuestas, los descartes y los finales; los iconos que usa cada app están en su `Assets.xcassets`.

## Licencias de terceros
Los LUTs de emulación de película que usa CamRemote Color vienen de [MokshC/Film-Emulation-LUTs](https://github.com/MokshC/Film-Emulation-LUTs) (MPL‑2.0). No están en este repositorio: se instalan en `~/Library/Application Support/CamRemote Color/LUTs`.
