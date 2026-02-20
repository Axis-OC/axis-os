-- /usr/commands/xe_modal_demo.lua

local xe       = require("xe")
local computer = require("computer")

local ctx = xe.createContext({
    theme = xe.THEMES.dark,
    extensions = {
        "XE_ui_shadow_buffering_render_batch",
        "XE_ui_diff_render_feature",
        "XE_ui_alt_screen_query",
        "XE_ui_deferred_clear",
        "XE_ui_imgui_navigation",
        "XE_ui_dirty_row_tracking",
        "XE_ui_run_length_grouping",
        "XE_ui_modal",
        "XE_ui_modal_prebuilt",
        "XE_ui_toast",
        "XE_ui_dropdown",
        "XE_ui_command_palette",
    },
})
if not ctx then print("xe: no context"); return end

local W, H = ctx.W, ctx.H
local running = true
local showAlert = false
local showConfirm = false
local showPrompt = false
local showSelect = false
local showPalette = false
local sUserName = "World"
local nThemeIdx = 1
local tThemes = {"Dark", "Light", "Solarized", "Retro"}
local frames = 0

local tCommands = {
    {id = "alert",   label = "Show Alert Dialog",     shortcut = "F1"},
    {id = "confirm", label = "Show Confirm Dialog",   shortcut = "F2"},
    {id = "prompt",  label = "Show Prompt Dialog",    shortcut = "F3"},
    {id = "select",  label = "Show Select Dialog",    shortcut = "F4"},
    {id = "toast_ok",label = "Toast: Success",        shortcut = "1"},
    {id = "toast_er",label = "Toast: Error",          shortcut = "2"},
    {id = "toast_wr",label = "Toast: Warning",        shortcut = "3"},
    {id = "quit",    label = "Quit Application",      shortcut = "Q"},
}

while running do
    ctx:beginFrame()
    ctx:clear(ctx:c("bg"))
    frames = frames + 1

    -- ---- Top bar ----
    ctx:fill(1, 1, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    ctx:text(2, 1, "XE Modal Demo", ctx:c("accent"), ctx:c("bar_bg"))
    ctx:textf(W - 20, 1, ctx:c("dim"), ctx:c("bar_bg"),
        "F:%d Ctrl+P:Palette", frames)

    -- ---- Main content ----
    ctx:text(3, 3, "Modal & Widget Demo", ctx:c("accent"))
    ctx:separator(3, 4, 40)
    ctx:textf(3, 5, ctx:c("fg"), nil, "Hello, %s!", sUserName)
    ctx:textf(3, 6, ctx:c("dim"), nil, "Theme: %s", tThemes[nThemeIdx])

    -- Buttons to open modals
    ctx:text(3, 8, "Dialogs:", ctx:c("accent2"))

    if ctx:button("btn_alert", 3, 9, " Alert (F1) ",
        ctx:c("btn_fg"), ctx:c("btn_bg"),
        ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        showAlert = true
    end
    if ctx:button("btn_confirm", 3, 10, " Confirm (F2) ",
        ctx:c("btn_fg"), ctx:c("btn_bg"),
        ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        showConfirm = true
    end
    if ctx:button("btn_prompt", 3, 11, " Prompt (F3) ",
        ctx:c("btn_fg"), ctx:c("btn_bg"),
        ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        showPrompt = true
    end
    if ctx:button("btn_select", 3, 12, " Select (F4) ",
        ctx:c("btn_fg"), ctx:c("btn_bg"),
        ctx:c("btn_hfg"), ctx:c("btn_hbg")) then
        showSelect = true
    end

    -- Dropdown
    ctx:text(3, 14, "Dropdown:", ctx:c("accent2"))
    local nNewTheme = ctx:dropdown("theme_dd", 3, 15, 20, tThemes, nThemeIdx)
    if nNewTheme then
        nThemeIdx = nNewTheme
        ctx:toastSuccess("Theme: " .. tThemes[nNewTheme])
    end

    -- Toast buttons
    ctx:text(3, 17, "Toasts (1-3):", ctx:c("accent2"))
    if ctx:button("btn_t1", 3, 18, " Success ",
        0xFFFFFF, 0x005500, 0xFFFFFF, 0x00AA00) then
        ctx:toastSuccess("Operation completed!")
    end
    if ctx:button("btn_t2", 14, 18, " Error ",
        0xFFFFFF, 0x880000, 0xFFFFFF, 0xFF0000) then
        ctx:toastError("Something went wrong!")
    end
    if ctx:button("btn_t3", 23, 18, " Warn ",
        0x000000, 0xAAAA00, 0x000000, 0xFFFF00) then
        ctx:toastWarn("Disk space low!")
    end

    -- Live info
    ctx:textf(45, 5, ctx:c("dim"), nil, "Free: %.1f KB",
        computer.freeMemory() / 1024)
    ctx:textf(45, 6, ctx:c("dim"), nil, "Modals open: %d",
        #ctx._modalStack)
    ctx:textf(45, 7, ctx:c("dim"), nil, "Toasts: %d",
        #ctx._toasts)

    -- ---- Modals (drawn on top of everything) ----

    if showAlert then
        if ctx:alert("dlg_alert", "Notice",
            "This is an alert dialog!") then
            showAlert = false
        end
    end

    if showConfirm then
        local r = ctx:confirm("dlg_confirm", "Delete?",
            "Remove all files?", "Delete", "Cancel")
        if r == true then
            showConfirm = false
            ctx:toastError("Files deleted! (not really)")
        elseif r == false then
            showConfirm = false
            ctx:toastInfo("Cancelled")
        end
    end

    if showPrompt then
        local r = ctx:prompt("dlg_prompt", "Rename",
            "Your name:", sUserName)
        if type(r) == "string" then
            sUserName = r
            showPrompt = false
            ctx:toastSuccess("Hello, " .. r .. "!")
        elseif r == false then
            showPrompt = false
        end
    end

    if showSelect then
        local r = ctx:selectModal("dlg_select", "Choose Theme",
            tThemes, nThemeIdx)
        if type(r) == "number" then
            nThemeIdx = r
            showSelect = false
            ctx:toastSuccess("Theme: " .. tThemes[r])
        elseif r == false then
            showSelect = false
        end
    end

    if showPalette then
        local r = ctx:commandPalette("cmdpal", tCommands)
        if r then
            showPalette = false
            if r == "quit" then running = false
            elseif r == "alert" then showAlert = true
            elseif r == "confirm" then showConfirm = true
            elseif r == "prompt" then showPrompt = true
            elseif r == "select" then showSelect = true
            elseif r == "toast_ok" then ctx:toastSuccess("Success!")
            elseif r == "toast_er" then ctx:toastError("Error!")
            elseif r == "toast_wr" then ctx:toastWarn("Warning!")
            end
        elseif r == false then
            showPalette = false
        end
    end

    -- ---- Status bar ----
    ctx:fill(1, H, W, 1, " ", ctx:c("bar_fg"), ctx:c("bar_bg"))
    if ctx:button("quit_btn", 2, H, " Quit ",
        ctx:c("btn_fg"), 0xAA2222,
        ctx:c("btn_hfg"), 0xFF4444) then
        running = false
    end

    -- ---- Global hotkeys ----
    local k = ctx:key()
    if k == "q" or k == "\3" then
        if ctx:hasModal() then
            ctx:closeModal(false)
        else
            running = false
        end
    elseif k == "\27[11~" then showAlert = true    -- F1
    elseif k == "\27[12~" then showConfirm = true  -- F2
    elseif k == "\27[13~" then showPrompt = true   -- F3
    elseif k == "\27[14~" then showSelect = true   -- F4
    elseif k == "\27[15~" or k == "\16" then       -- F5 / Ctrl+P
        showPalette = true
    elseif k == "1" and not ctx:hasModal() then
        ctx:toastSuccess("Quick toast!")
    elseif k == "2" and not ctx:hasModal() then
        ctx:toastError("Quick error!")
    elseif k == "3" and not ctx:hasModal() then
        ctx:toastWarn("Quick warning!")
    end

    ctx:endFrame()
end

ctx:destroy()