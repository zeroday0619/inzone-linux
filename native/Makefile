CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -ffp-contract=off
all: inzone_dsp.so
inzone_dsp.so: ladspa.c dynamics.c spatial_alc.c dynamics.h spatial_alc.h
	$(CC) $(CFLAGS) -Wno-missing-field-initializers -fPIC -shared -o $@ ladspa.c dynamics.c spatial_alc.c -lm

PLUGIN_HASH = $(shell sha256sum inzone_dsp.so 2>/dev/null | cut -c1-16)
install: inzone_dsp.so
	install -d $(DESTDIR)/usr/lib/ladspa
	install -m 0755 inzone_dsp.so $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so.new
	mv $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so.new $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so
