import QtQuick
import HomeOS

// Soft blue → coral → amber arch, painted once per resize. Used behind the
// assistant and in the photo frame's empty state.
Canvas {
    id: glow
    property real intensity: 1.0
    renderStrategy: Canvas.Cooperative
    // Repaint as the mood palette animates.
    readonly property var colors: [Theme.glowBlue, Theme.glowCoral, Theme.glowAmber, Theme.glowCream]
    onColorsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        const w = width, h = height
        if (w <= 0 || h <= 0) return

        // Arch centred low and to the right, sweeping up from the bottom-left.
        const cx = w * 0.62, cy = h * 1.18, r = Math.max(w, h) * 0.78
        const grad = ctx.createLinearGradient(0, 0, w, 0)
        grad.addColorStop(0.00, glow.colors[0])
        grad.addColorStop(0.40, glow.colors[1])
        grad.addColorStop(0.72, glow.colors[2])
        grad.addColorStop(1.00, glow.colors[3])
        ctx.strokeStyle = grad
        ctx.lineCap = "round"

        // Many wide, faint passes approximate a blur without shader effects.
        const band = h * 0.16
        for (let i = 0; i < 16; ++i) {
            ctx.globalAlpha = 0.06 * glow.intensity
            ctx.lineWidth = band * (0.35 + i * 0.16)
            ctx.beginPath()
            ctx.arc(cx, cy, r, Math.PI * 1.02, Math.PI * 1.98, false)
            ctx.stroke()
        }
        // Bright core of the band.
        ctx.globalAlpha = 0.55 * glow.intensity
        ctx.lineWidth = band * 0.55
        ctx.beginPath()
        ctx.arc(cx, cy, r, Math.PI * 1.02, Math.PI * 1.98, false)
        ctx.stroke()
    }
}
