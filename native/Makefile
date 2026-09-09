SWIFTC ?= swiftc
SWIFT_DSP_FLAGS ?= -O -whole-module-optimization
MODULE_CACHE ?= ../.build/native-module-cache
SWIFT_SOURCES := $(wildcard ../Sources/InzoneDSP/*.swift)
DEBUG_OBJECT := debug.o

.PHONY: all install
all: inzone_dsp.so
inzone_dsp.so: $(SWIFT_SOURCES) $(DEBUG_OBJECT) ../Sources/CLADSPA/include/header.h ../Sources/CLADSPA/module.modulemap exports.map Makefile
	env -u CC -u CXX -u LD -u AR -u CFLAGS -u CXXFLAGS -u LDFLAGS "$(SWIFTC)" \
		-swift-version 6 -module-name InzoneDSP -parse-as-library $(SWIFT_DSP_FLAGS) \
		-enable-experimental-feature Embedded \
		-module-cache-path "$(MODULE_CACHE)" -I ../Sources/CLADSPA \
		-emit-library $(SWIFT_SOURCES) $(DEBUG_OBJECT) -lm \
		-Xlinker --version-script=exports.map -Xlinker --exclude-libs=ALL \
		-Xlinker -z -Xlinker now -Xlinker -fini -Xlinker inzone_dsp_finalize \
		-o "$@.new"
	mv "$@.new" "$@"

$(DEBUG_OBJECT): debug.c ../Sources/CLADSPA/include/header.h
	$(CC) -O2 -fPIC -I ../Sources/CLADSPA/include -c debug.c -o $@

PLUGIN_HASH = $(shell sha256sum inzone_dsp.so 2>/dev/null | cut -c1-16)
install: inzone_dsp.so
	install -d $(DESTDIR)/usr/lib/ladspa
	install -m 0755 inzone_dsp.so $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so.new
	mv $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so.new $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so
