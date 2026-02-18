--
-- /lib/signal_lib.lua — User-space signal API
--

local oSig = {}

oSig.SIGHUP=1  oSig.SIGINT=2  oSig.SIGQUIT=3  oSig.SIGILL=4
oSig.SIGABRT=6 oSig.SIGKILL=9 oSig.SIGPIPE=13 oSig.SIGALRM=14
oSig.SIGTERM=15 oSig.SIGCHLD=17 oSig.SIGCONT=18 oSig.SIGSTOP=19
oSig.SIGTSTP=20 oSig.SIGUSR1=30 oSig.SIGUSR2=31

oSig.SIG_DFL = nil   -- pass nil to reset to default
oSig.SIG_IGN = function() end  -- ignore handler

function oSig.handle(nSignal, fHandler)
    return syscall("ke_signal_handler", nSignal, fHandler)
end

function oSig.send(nPid, nSignal)
    return syscall("ke_signal_send", nPid, nSignal)
end

function oSig.sendGroup(nPgid, nSignal)
    return syscall("ke_signal_group", nPgid, nSignal)
end

function oSig.mask(tMask)
    return syscall("ke_signal_mask", tMask)
end

function oSig.setpgid(nPid, nPgid)
    return syscall("ke_setpgid", nPid, nPgid)
end

function oSig.getpgid()
    return syscall("ke_getpgid")
end

return oSig