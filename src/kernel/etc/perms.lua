--
-- /etc/perms.lua
-- AxisOS File System Permissions
--
return {
  ["/"]            = { uid = 0, gid = 0, mode = 755 },
  ["/bin"]         = { uid = 0, gid = 0, mode = 755 },
  ["/boot"]        = { uid = 0, gid = 0, mode = 755 },
  ["/dev"]         = { uid = 0, gid = 0, mode = 755 },
  ["/drivers"]     = { uid = 0, gid = 0, mode = 755 },
  ["/etc"]         = { uid = 0, gid = 0, mode = 755 },
  ["/lib"]         = { uid = 0, gid = 0, mode = 755 },
  ["/sys"]         = { uid = 0, gid = 0, mode = 755 },
  ["/system"]      = { uid = 0, gid = 0, mode = 755 },
  ["/usr"]         = { uid = 0, gid = 0, mode = 755 },
  ["/log"]         = { uid = 0, gid = 0, mode = 755 },
  ["/vbl"]         = { uid = 0, gid = 0, mode = 755 },

  ["/home"]        = { uid = 0, gid = 0, mode = 755 },
  ["/home/guest"]  = { uid = 1000, gid = 0, mode = 755 },
  ["/tmp"]         = { uid = 0, gid = 0, mode = 777 },

  ["/kernel.lua"]                 = { uid = 0, gid = 0, mode = 644 },
  ["/bin/init.lua"]               = { uid = 0, gid = 0, mode = 644 },
  ["/bin/sh.lua"]                 = { uid = 0, gid = 0, mode = 644 },
  ["/system/dkms.lua"]            = { uid = 0, gid = 0, mode = 644 },
  ["/system/driverdispatch.lua"]  = { uid = 0, gid = 0, mode = 644 },
  ["/lib/pipeline_manager.lua"]   = { uid = 0, gid = 0, mode = 644 },
  ["/sys/security/patchguard.lua"]= { uid = 0, gid = 0, mode = 644 },
  ["/sys/security/dkms_sec.lua"]  = { uid = 0, gid = 0, mode = 644 },
  ["/sys/security/hvci.lua"]      = { uid = 0, gid = 0, mode = 644 },

  ["/etc/passwd.lua"]             = { uid = 0, gid = 0, mode = 600 },
  ["/etc/perms.lua"]              = { uid = 0, gid = 0, mode = 600 },
  ["/etc/pki.cfg"]                = { uid = 0, gid = 0, mode = 600 },
  ["/etc/sys.cfg"]                = { uid = 0, gid = 0, mode = 644 },
  ["/etc/fstab.lua"]              = { uid = 0, gid = 0, mode = 644 },
  ["/etc/drivers.cfg"]            = { uid = 0, gid = 0, mode = 644 },
  ["/boot/loader.cfg"]            = { uid = 0, gid = 0, mode = 644 },
  ["/etc/pki_keystore.lua"]       = { uid = 0, gid = 0, mode = 644 },

  ["/etc/signing"]                = { uid = 0, gid = 0, mode = 700 },
  ["/etc/signing/private.key"]    = { uid = 0, gid = 0, mode = 600 },
  ["/etc/signing/public.key"]     = { uid = 0, gid = 0, mode = 644 },

  ["/dev/tty"]                    = { uid = 0, gid = 0, mode = 666 },
  ["/dev/gpu0"]                   = { uid = 0, gid = 0, mode = 666 },
  ["/dev/ringlog"]                = { uid = 0, gid = 0, mode = 666 },
  ["/dev/net"]                    = { uid = 0, gid = 0, mode = 666 },
}