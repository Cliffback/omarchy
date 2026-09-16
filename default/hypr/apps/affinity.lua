-- Affinity runs under Wine. Its document window is tiled, but the welcome,
-- open/save, and preferences dialogs arrive as separate top-level windows
-- (usually with an empty title) and spawn at the top-left corner instead of
-- centered. Center only affects floating windows, so the tiled document
-- window is untouched.
o.window("affinity.exe", { center = true })

-- Colour-critical editing: keep fully opaque instead of the default
-- translucency, which distorts the canvas.
o.window("affinity.exe", { tag = "-default-opacity", opacity = "1 1" })
