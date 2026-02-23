--
-- /usr/commands/gdi_demo.lua
-- GDI v2 Demo — Multi-GPU, Swapchains, Surfaces
--

local fs = require("filesystem")

local C = {
    R = "\27[37m", G = "\27[32m", Y = "\27[33m",
    C = "\27[36m", M = "\27[35m",
}

print(C.C .. "═══════════════════════════════════════" .. C.R)
print(C.C .. "  GDI v2 Demo — GPU-Accelerated Output " .. C.R)
print(C.C .. "═══════════════════════════════════════" .. C.R)
print("")

-- ─── Query GPU configuration ───

local nGpuCount = syscall("gdi_get_gpu_count")
print(C.Y .. "GPUs detected: " .. C.R .. tostring(nGpuCount))

for i = 1, nGpuCount do
    local tInfo = syscall("gdi_get_gpu_info", i)
    if tInfo then
        print(string.format("  GPU %d: %s → %s (%dx%d)",
            i,
            tInfo.address:sub(1, 8) .. "...",
            tInfo.screenAddr and (tInfo.screenAddr:sub(1, 8) .. "...") or "unbound",
            tInfo.nW, tInfo.nH))
    end
end
print("")

-- Check GPU driver fast-path
local bFastPath = syscall("gdi_has_gpu_driver")
print(C.M .. "GPU Driver Fast-Path: " .. C.R
    .. (bFastPath and (C.G .. "ACTIVE") or (C.Y .. "DIRECT MODE")) .. C.R)
print("")

-- ─── Create surfaces on GPU 1 ───

local tInfo1 = syscall("gdi_get_gpu_info", 1)
if not tInfo1 then
    print("No GPU available.")
    return
end

local W, H = tInfo1.nW, tInfo1.nH

-- Surface 1: status bar at top
local hBar = syscall("gdi_create_surface", W, 1, {
    bVisible = true,
    nScreenX = 1,
    nScreenY = 1,
    nZOrder  = 10,
    sLabel   = "StatusBar",
})

-- Surface 2: main content area
local hMain = syscall("gdi_create_surface", W, H - 2, {
    bVisible = true,
    nScreenX = 1,
    nScreenY = 2,
    nZOrder  = 5,
    sLabel   = "MainContent",
})

-- Surface 3: bottom bar
local hBottom = syscall("gdi_create_surface", W, 1, {
    bVisible = true,
    nScreenX = 1,
    nScreenY = H,
    nZOrder  = 10,
    sLabel   = "BottomBar",
})

-- ─── Draw to surfaces ───

-- Status bar: white on blue
syscall("gdi_surface_fill", hBar, 1, 1, W, 1, " ", 0xFFFFFF, 0x0000AA)
syscall("gdi_surface_set", hBar, 2, 1,
    " GDI v2 Demo | GPU-Accelerated | " ..
    (bFastPath and "Fast-Path Active" or "Direct Mode"),
    0xFFFFFF, 0x0000AA)

-- Main area: dark background with colored text
syscall("gdi_surface_clear", hMain, 0xCCCCDD, 0x0C0C1E)

local nY = 2
local function drawLine(s, fg)
    syscall("gdi_surface_set", hMain, 3, nY, s, fg or 0xCCCCDD, 0x0C0C1E)
    nY = nY + 1
end

drawLine("GDI v2 Features:", 0x55FFFF)
drawLine("")
drawLine("  [✓] GPU Driver fast-path (zero IRP overhead)", 0x55FF55)
drawLine("  [✓] Multi-GPU native support", 0x55FF55)
drawLine("  [✓] Swapchain commands", 0x55FF55)
drawLine("  [✓] Command buffers", 0x55FF55)
drawLine("  [✓] Pipeline state cache (skip redundant color calls)", 0x55FF55)
drawLine("  [✓] Color-sorted batch compositor", 0x55FF55)
drawLine("  [✓] Multi-GPU broadcast drawing", 0x55FF55)
drawLine("")
drawLine("Surface Compositing:", 0xFFFF55)
drawLine("")
drawLine("  Three surfaces are composited onto GPU 1:", 0xAAAAAA)
drawLine("    • StatusBar  (Z=10, row 1)", 0xAAAAAA)
drawLine("    • MainContent (Z=5, rows 2-" .. (H-1) .. ")", 0xAAAAAA)
drawLine("    • BottomBar   (Z=10, row " .. H .. ")", 0xAAAAAA)

-- ─── Multi-GPU broadcast demo ───

if nGpuCount > 1 then
    nY = nY + 1
    drawLine("Multi-GPU:", 0xFF55FF)
    drawLine("")
    drawLine("  Broadcasting colored text to ALL " .. nGpuCount .. " GPUs...", 0xAAAAAA)

    -- Broadcast a draw to all GPUs simultaneously
    local tBroadcast = {}
    local sMsg = " Hello from all GPUs! "
    for i = 1, #sMsg do
        local nHue = math.floor(i / #sMsg * 0xFF)
        local nColor = nHue * 0x10000 + (0xFF - nHue) * 0x100 + 0x80
        tBroadcast[i] = { i + 2, H - 3, sMsg:sub(i, i), nColor, 0x111122 }
    end
    syscall("gdi_multi_gpu_draw", tBroadcast)
    drawLine("  Done! Check all screens.", 0x55FF55)
else
    nY = nY + 1
    drawLine("(Single GPU — multi-GPU broadcast requires 2+ GPUs)", 0x555555)
end

-- ─── Swapchain demo ───

nY = nY + 1
drawLine("Swapchain:", 0x55FFFF)
if bFastPath then
    local hSwap = syscall("gdi_create_swapchain", 1)
    if hSwap then
        drawLine("  Created swapchain #" .. tostring(hSwap), 0x55FF55)
        local nBuf = syscall("gdi_acquire_image", hSwap)
        drawLine("  Acquired back buffer: " .. tostring(nBuf), 0xAAAAAA)
        syscall("gdi_present_swapchain", hSwap)
        drawLine("  Present complete (buffer swapped)", 0x55FF55)
        syscall("gdi_destroy_swapchain", hSwap)
        drawLine("  Swapchain destroyed (cleanup OK)", 0xAAAAAA)
    else
        drawLine("  Swapchain creation failed (Tier 3 GPU required)", 0xFF5555)
    end
else
    drawLine("  (requires GPU driver fast-path)", 0x555555)
end

-- Bottom bar
syscall("gdi_surface_fill", hBottom, 1, 1, W, 1, " ", 0x000000, 0xFFFF00)
syscall("gdi_surface_set", hBottom, 2, 1,
    " Press any key to exit ",
    0x000000, 0xFFFF00)

-- ─── Composite and wait ───

syscall("gdi_composite")

-- Wait for keypress
local hTtyIn = fs.open("/dev/tty", "r")
fs.deviceControl(hTtyIn, "set_mode", {"raw"})
fs.read(hTtyIn)
fs.deviceControl(hTtyIn, "set_mode", {"cooked"})
fs.close(hTtyIn)

-- ─── Cleanup ───

syscall("gdi_destroy_surface", hBar)
syscall("gdi_destroy_surface", hMain)
syscall("gdi_destroy_surface", hBottom)

print("")
print(C.G .. "Demo complete." .. C.R)