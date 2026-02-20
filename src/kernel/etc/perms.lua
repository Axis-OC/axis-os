return {
  ["/etc/pki_keystore.lua"] = { uid = 0, gid = 0, mode = 600 },
  ["/all_code.txt"] = { uid = 1000, gid = 0, mode = 777 },
  ["/etc/perms.lua"] = { uid = 0, gid = 0, mode = 600 },
  ["/boot/kernel.lua"] = { uid = 0, gid = 0, mode = 400 },
  ["/etc/pki.cfg"] = { uid = 0, gid = 0, mode = 600 },
  ["/dev/gpu0"] = { uid = 0, gid = 0, mode = 660 },
  ["/dev/ringlog"] = { uid = 0, gid = 0, mode = 644 },
  ["/etc/passwd.lua"] = { uid = 0, gid = 0, mode = 600 },
  ["/dev/tty"] = { uid = 0, gid = 0, mode = 666 },
  ["/etc/signing/private.key"] = { uid = 0, gid = 0, mode = 600 },
  ["/etc/secureboot.cfg"] = { uid = 0, gid = 0, mode = 600 },

  -- System directories: read-only for all non-kernel processes
  -- uid=0 gid=0 mode=755 means: owner(root) rwx, group rx, others rx
  -- Write requires uid=0 AND Ring ≤ 1 (enforced by VFS)

  ["/sys"]                     = { uid = 0, gid = 0, mode = 755, ring = 1 },
  ["/sys/drivers"]             = { uid = 0, gid = 0, mode = 755, ring = 1 },
  ["/sys/drivers/gpu.lua"]     = { uid = 0, gid = 0, mode = 644, ring = 1 },
  ["/sys/drivers/fs.lua"]      = { uid = 0, gid = 0, mode = 644, ring = 1 },
  ["/sys/drivers/net.lua"]     = { uid = 0, gid = 0, mode = 644, ring = 1 },
  ["/sys/drivers/eeprom.lua"]  = { uid = 0, gid = 0, mode = 644, ring = 1 },

  -- Also protect /bin, /sbin, /etc from Ring 3 writes
  ["/bin"]                     = { uid = 0, gid = 0, mode = 755, ring = 1 },
  ["/sbin"]                    = { uid = 0, gid = 0, mode = 755, ring = 1 },
  ["/etc"]                     = { uid = 0, gid = 0, mode = 755, ring = 2 },

}