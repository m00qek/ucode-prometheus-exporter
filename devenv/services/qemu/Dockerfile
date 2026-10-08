# QEMU for make bench-qemu: OpenWrt's malta target, little-endian (mipsel_24kc)
# under qemu-system-mipsel or big-endian (mips_24kc) under qemu-system-mips, its
# root filesystem written with debugfs (no mount).
FROM alpine:3.21

RUN apk add --no-cache qemu-system-mipsel qemu-system-mips e2fsprogs e2fsprogs-extra coreutils tar gzip wget
