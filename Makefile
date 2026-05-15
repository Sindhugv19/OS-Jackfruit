CC      := gcc
CFLAGS  := -Wall -Wextra -g -O2 -D_GNU_SOURCE
LDFLAGS := -lpthread
KDIR    := /lib/modules/$(shell uname -r)/build
PWD_DIR := $(shell pwd)

obj-m += monitor.o

all: engine cpu_hog io_pulse memory_hog
	$(MAKE) -C $(KDIR) M=$(PWD_DIR) modules

ci: engine cpu_hog io_pulse memory_hog

engine: engine.c monitor_ioctl.h
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

cpu_hog: cpu_hog.c
	$(CC) $(CFLAGS) -o $@ $

io_pulse: io_pulse.c
	$(CC) $(CFLAGS) -o $@ $

memory_hog: memory_hog.c
	$(CC) $(CFLAGS) -o $@ $

static: cpu_hog.c io_pulse.c memory_hog.c
	$(CC) $(CFLAGS) -static -o cpu_hog_static cpu_hog.c
	$(CC) $(CFLAGS) -static -o io_pulse_static io_pulse.c
	$(CC) $(CFLAGS) -static -o memory_hog_static memory_hog.c

clean:
	rm -f engine cpu_hog io_pulse memory_hog cpu_hog_static io_pulse_static memory_hog_static
	$(MAKE) -C $(KDIR) M=$(PWD_DIR) clean 2>/dev/null || true
