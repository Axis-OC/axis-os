-- AxisOS File System Table
return {
  { uuid = "b40e1090-01ba-4189-95d5-d44a0d9f5b48", path = "/", mount = "/", type = "rootfs", options = "rw", },
  { uuid = "b40e1090-01ba-4189-95d5-d44a0d9f5b48", path = "/home", mount = "/home", type = "homefs", options = "rw,size=3000", },
  { uuid = "b40e1090-01ba-4189-95d5-d44a0d9f5b48", path = "/swapfile", mount = "none", type = "swap", options = "size=3000", },
  { uuid = "b40e1090-01ba-4189-95d5-d44a0d9f5b48", path = "/log", mount = "/var/log", type = "ringfs", options = "rw,size=3000", },
  { uuid = "virtual", path = "/dev/ringlog", mount = "/var/log/syslog", type = "ringfs", options = "rw,size=8192" },
}
