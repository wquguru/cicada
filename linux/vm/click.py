#!/usr/bin/env python3
import fcntl
import os
import struct
import sys
import time

x, y = int(sys.argv[1]), int(sys.argv[2])
to = (int(sys.argv[4]), int(sys.argv[5])) if len(sys.argv) > 5 and sys.argv[3] == "--to" else None
w, h = 1600, 1000
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_X, ABS_Y, BTN_LEFT = 0, 1, 272
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045567
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
for ev in (EV_KEY, EV_ABS):
    fcntl.ioctl(fd, UI_SET_EVBIT, ev)
fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
for a in (ABS_X, ABS_Y):
    fcntl.ioctl(fd, UI_SET_ABSBIT, a)
absmax = [0] * 64
absmax[ABS_X], absmax[ABS_Y] = w - 1, h - 1
dev = struct.pack("80sHHHHI", b"cicada-test-pointer", 3, 1, 1, 1, 0) + struct.pack("64i", *absmax) + struct.pack("64i", *([0] * 64)) * 3
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.0)


def emit(t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))


def sync():
    emit(EV_SYN, 0, 0)


emit(EV_ABS, ABS_X, x); emit(EV_ABS, ABS_Y, y); sync(); time.sleep(0.2)
emit(EV_KEY, BTN_LEFT, 1); sync(); time.sleep(0.1)
if to:
    for i in range(1, 21):
        emit(EV_ABS, ABS_X, x + (to[0] - x) * i // 20); emit(EV_ABS, ABS_Y, y + (to[1] - y) * i // 20); sync(); time.sleep(0.03)
emit(EV_KEY, BTN_LEFT, 0); sync(); time.sleep(0.3)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
