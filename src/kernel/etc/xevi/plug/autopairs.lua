--
-- autopairs.lua — Auto-close brackets and quotes
--
local tPairs = {
    ["("] = ")",
    ["["] = "]",
    ["{"] = "}",
    ['"'] = '"',
    ["'"] = "'",
}

local bEnabled = true

return {
    name        = "autopairs",
    version     = "1.0.0",
    description = "Auto-close brackets and quotes in insert mode",

    on_load = function(api, opts)
        if opts.pairs then
            tPairs = {}
            for _, sPair in ipairs(opts.pairs) do
                tPairs[sPair:sub(1, 1)] = sPair:sub(2, 2)
            end
        end
        if opts.enabled == false then bEnabled = false end
    end,

    on_insert_char = function(api, buf, ch)
        if not bEnabled then return ch end
        local sClose = tPairs[ch]
        if sClose then
            -- Return both chars — xevi will insert the whole string
            return ch .. sClose
        end
        return ch
    end,

    commands = {
        {
            cmd  = "APToggle",
            desc = "Toggle autopairs on/off",
            func = function(api)
                bEnabled = not bEnabled
                api.toast("Autopairs: " .. (bEnabled and "ON" or "OFF"))
            end,
        },
    },
}