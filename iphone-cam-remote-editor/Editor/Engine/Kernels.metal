// Kernels de Core Image (Metal, [[stitchable]]) para CamRemote Color.
// Espacio de trabajo: lineal extendido BT.2020 (half float). Nada se recorta.

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

namespace camremote {

// Curva Apple Log (Apple Log Profile White Paper). Apple Log 2 usa la misma curva.
constant float ALOG_R0 = -0.05641088;
constant float ALOG_RT = 0.01;
constant float ALOG_C = 47.28711236;
constant float ALOG_B = 0.00964052;
constant float ALOG_G = 0.08550479;
constant float ALOG_BETA = 0.69336945;

inline float alogDecode(float p) {
    float pt = ALOG_C * (ALOG_RT - ALOG_R0) * (ALOG_RT - ALOG_R0);
    if (p >= pt) return exp2((p - ALOG_BETA) / ALOG_G) - ALOG_B;
    if (p >= 0.0) return sqrt(p / ALOG_C) + ALOG_R0;
    return ALOG_R0;
}

inline float alogEncode(float x) {
    if (x >= ALOG_RT) return ALOG_G * log2(x + ALOG_B) + ALOG_BETA;
    if (x >= ALOG_R0) return ALOG_C * (x - ALOG_R0) * (x - ALOG_R0);
    return 0.0;
}

// Espacio de etalonado: curva ACEScct normalizada para que lineal 0 → 0 y lineal 1 → 1.
// Por encima de 1 sigue subiendo (HDR) sin recortar.
constant float CCT0 = 0.0729055341958355;
constant float CCT1 = 0.5547945205479452;

inline float linToCct(float x) {
    return x <= 0.0078125 ? 10.5402377416545 * x + CCT0 : (log2(x) + 9.72) / 17.52;
}
inline float cctToLin(float y) {
    return y <= 0.155251141552511 ? (y - CCT0) / 10.5402377416545 : exp2(y * 17.52 - 9.72);
}
inline float linToN(float x) { return (linToCct(x) - CCT0) / (CCT1 - CCT0); }
inline float nToCct(float n) { return n * (CCT1 - CCT0) + CCT0; }
inline float cctToN(float c) { return (c - CCT0) / (CCT1 - CCT0); }

constant float3 LUMA2020 = float3(0.2627, 0.6780, 0.0593);
constant float PIVOT = 0.70697; // gris 18 % en el espacio de etalonado

}

using namespace camremote;

extern "C" {

[[stitchable]] float4 appleLogToLinear(coreimage::sample_t s) {
    return float4(alogDecode(s.r), alogDecode(s.g), alogDecode(s.b), s.a);
}

[[stitchable]] float4 linearToAppleLog(coreimage::sample_t s) {
    return float4(alogEncode(s.r), alogEncode(s.g), alogEncode(s.b), s.a);
}

[[stitchable]] float4 gradingToLinear(coreimage::sample_t s) {
    return float4(cctToLin(s.r), cctToLin(s.g), cctToLin(s.b), s.a);
}

// Etalonado primario. Entrada: lineal. Salida: espacio ACEScct (para el cubo de curvas/HSL).
// tones = (altas luces, sombras, blancos, negros); satVib = (saturación, vibrancia)
[[stitchable]] float4 primaryGrade(coreimage::sample_t s,
                                   float exposure,
                                   float3 wb,
                                   float4 tones,
                                   float contrast,
                                   float2 satVib,
                                   float3 lift,
                                   float3 gamma,
                                   float3 gain) {
    float3 c = s.rgb * exp2(exposure) * wb;
    float3 n = float3(linToN(c.r), linToN(c.g), linToN(c.b));

    // Tonos: desplazamientos en log (= ganancia en lineal → conserva el tono de color).
    float l = dot(n, LUMA2020);
    float sh = 1.0 - smoothstep(0.0, 0.65, l);
    float hi = smoothstep(0.45, 1.0, l);
    float wh = smoothstep(0.75, 1.25, l);
    float bl = 1.0 - smoothstep(0.0, 0.35, l);
    n += tones.x * 0.20 * hi + tones.y * 0.20 * sh + tones.z * 0.15 * wh + tones.w * 0.10 * bl;

    // Contraste alrededor del gris medio.
    n = PIVOT + (n - PIVOT) * (1.0 + contrast);

    // Saturación y vibrancia.
    l = dot(n, LUMA2020);
    float3 cn = clamp(n, 0.0, 1.0);
    float satAmt = max(cn.r, max(cn.g, cn.b)) - min(cn.r, min(cn.g, cn.b));
    float vib = 1.0 + satVib.y * (1.0 - smoothstep(0.0, 0.45, satAmt));
    n = l + (n - l) * max(0.0, 1.0 + satVib.x) * max(0.0, vib);

    // Ruedas lift / gamma / gain.
    n = n + lift * (1.0 - clamp(n, 0.0, 1.0));
    n = sign(n) * pow(abs(n), 1.0 / max(gamma, float3(0.05)));
    n = n * gain;

    return float4(nToCct(n.r), nToCct(n.g), nToCct(n.b), s.a);
}

// Compresión suave de altas luces hacia el pico del destino (1.0 SDR, 4.926 HLG).
[[stitchable]] float4 softClip(coreimage::sample_t s, float peak) {
    float3 c = max(s.rgb, float3(-0.01));
    float m = max(c.r, max(c.g, c.b));
    float knee = 0.8 * peak;
    if (m > knee) {
        float range = peak - knee;
        float nm = knee + range * (1.0 - exp(-(m - knee) / range));
        c *= nm / m;
    }
    return float4(c, s.a);
}

[[stitchable]] float4 mixImages(coreimage::sample_t a, coreimage::sample_t b, float t) {
    return mix(a, b, t);
}

}
