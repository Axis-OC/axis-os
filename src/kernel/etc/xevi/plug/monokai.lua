--
-- colorscheme_monokai.lua — Monokai color theme
--
return {
    name        = "monokai",
    version     = "1.0.0",
    description = "Monokai color scheme for xevi",

    colors = {
        bg       = 0x272822,
        fg       = 0xF8F8F2,
        gutter   = 0x90908A,
        gutterBg = 0x2D2E27,
        curLine  = 0x3E3D32,
        cursor   = 0xF8F8F0,
        tilde    = 0x464741,
        tabBg    = 0x1E1F1C,
        tabFg    = 0x90908A,
        tabAct   = 0xA6E22E,
        tabActBg = 0x272822,
        barBg    = 0x1E1F1C,
        barFg    = 0xF8F8F2,
        modeN    = 0xA6E22E,
        modeI    = 0xF92672,
        modeC    = 0x66D9EF,
        modeS    = 0xE6DB74,
        dropBg   = 0x1E1F1C,
        dropSel  = 0xA6E22E,
        dropSelBg= 0x3E3D32,
        dropCmd  = 0x66D9EF,
    },

    highlights = {
        keyword  = 0xF92672,
        builtin  = 0x66D9EF,
        string   = 0xE6DB74,
        number   = 0xAE81FF,
        comment  = 0x75715E,
        operator = 0xF92672,
    },

    on_load = function(api, opts)
        api.toast("Monokai theme active")
    end,
}