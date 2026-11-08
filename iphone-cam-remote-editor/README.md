# CamRemote Color

App de macOS (SwiftUI + AVFoundation + Core Image/Metal) para etalonar los vídeos de CamRemote.

- Proyecto: `xcodegen generate` → `CamRemoteEditor.xcodeproj` (macOS 15+, equipo Z8GY99W9QQ,
  `com.adrianmillares.camremote.editor`). Requiere el Metal Toolchain de Xcode
  (`xcodebuild -downloadComponent MetalToolchain`).
- Procesado: half float, lineal BT.2020 extendido (no recorta HDR). Apple Log/Log 2 se decodifican con
  kernel propio (Log 2 = misma curva; gamut Apple Wide Gamut aproximado como BT.2020).
- Exportación: AVAssetReader/Writer con compositor propio; audio en passthrough (bit a bit).
- LUTs y presets del usuario: `~/Library/Application Support/CamRemote Color/{LUTs,Presets}`.
- Modo sin interfaz (pruebas/lotes):
  `"CamRemote Color.app/Contents/MacOS/CamRemote Color" --export in.mov out.mov [--preset builtin.teal_orange]
  [--lut x.cube --intensity 0.8] [--format prores422HQ|prores4444|hevc10] [--output hlg2020|rec709|p3d65]`
