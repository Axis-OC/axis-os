## 11. Driver Objects & Structure

### 11.1 DRIVER_OBJECT

Created by DKMS for each loaded driver. Contains the driver's identity and dispatch table:

```lua
{
    sDriverPath   = "/drivers/tty.sys.lua",
    nDriverPid    = 7,
    pDeviceObject = <first device in linked list>,
    fDriverUnload = function(pDriverObject) ... end,
    tDispatch     = {
        [0x00] = fCreate,          -- IRP_MJ_CREATE
        [0x02] = fClose,           -- IRP_MJ_CLOSE
        [0x03] = fRead,            -- IRP_MJ_READ
        [0x04] = fWrite,           -- IRP_MJ_WRITE
        [0x0E] = fDeviceControl,   -- IRP_MJ_DEVICE_CONTROL
    },
    tDriverInfo   = { ... },       -- copy of g_tDriverInfo
}
```

### 11.2 DEVICE_OBJECT

Represents a single device instance managed by a driver:

```lua
{
    pDriverObject    = <back-pointer to driver>,
    pNextDevice      = nil,             -- linked list
    sDeviceName      = "\\Device\\TTY0",
    pDeviceExtension = {                -- driver's private scratchpad
        -- TTY example:
        nWidth      = 80,
        nHeight     = 25,
        nCursorX    = 1,
        nCursorY    = 25,
        sLineBuffer = "",
        tScreenRows = {},
        -- ... etc.
    },
    nFlags           = 0,

    -- Added by DKMS for registry integration:
    sRegistryId   = "VIRT_001",
    sRegistryPath = "@VT\\DEV\\VIRT_001",
}
```

### 11.3 g_tDriverInfo — Driver Metadata

Every driver **must** declare a global `g_tDriverInfo` table:

```lua
g_tDriverInfo = {
    sDriverName        = "AxisTTY",              -- REQUIRED: unique name
    sDriverType        = tDKStructs.DRIVER_TYPE_KMD,  -- REQUIRED: KMD/CMD/UMD
    nLoadPriority      = 100,                    -- REQUIRED: lower = earlier
    sVersion           = "5.1.0",                -- optional
    sSupportedComponent = nil,                    -- CMD only: component type
}
```

**Driver Types:**

| Constant | Ring | Description |
|----------|------|-------------|
| `DRIVER_TYPE_KMD` | 2 | Kernel Mode Driver — full access, no hardware requirement |
| `DRIVER_TYPE_CMD` | 2 | Component Mode Driver — bound to specific hardware component |
| `DRIVER_TYPE_UMD` | 3 | User Mode Driver — sandboxed, communicates through host |

---