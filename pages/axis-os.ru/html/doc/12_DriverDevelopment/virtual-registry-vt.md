## 14. Virtual Registry (@VT)

### 14.1 Overview

The Virtual Registry provides a hierarchical key-value store for device, driver, and system metadata. It is similar to the Windows Registry but exists only in memory (not persisted to disk).

### 14.2 Path Format

```
@VT\DEV\VIRT_001         Device registry entries
@VT\DRV\AxisTTY          Driver registry entries
@VT\SYS\BOOT             Boot-time system info
@VT\SYS\CONFIG           Parsed /etc/sys.cfg values
@VT\SYS\HARDWARE         Enumerated hardware components
```

### 14.3 Value Types

| Type | Tag | Example |
|------|-----|---------|
| String | `STR` | `"AxisTTY"` |
| Number | `NUM` | `100` |
| Boolean | `BOOL` | `true` |
| Table | `TAB` | `{...}` |

### 14.4 CLI Usage

```bash
reg tree @VT            # Show full tree
reg query @VT\DRV       # List driver keys
reg get @VT\SYS\BOOT KernelVersion  # Get specific value
```

### 14.5 Auto-Populated Keys

DKMS automatically populates `@VT\DEV\*` when devices are created:

```
@VT\DEV\VIRT_001
  DeviceName    = "\\Device\\TTY0"     (STR)
  DriverName    = "AxisTTY"            (STR)
  DriverPID     = 7                    (NUM)
  DriverType    = "KernelModeDriver"   (STR)
  DriverVersion = "5.1.0"             (STR)
  DeviceClass   = "virtual"           (STR)
  Symlink       = "/dev/tty"          (STR)
  FriendlyName  = "tty"              (STR)
  Status        = "online"            (STR)
```

---