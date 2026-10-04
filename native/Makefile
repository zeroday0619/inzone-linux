SWIFTC ?= swiftc
SWIFT_DSP_FLAGS ?= -O -whole-module-optimization
MODULE_CACHE ?= ../.build/native-module-cache
SWIFT_SOURCES := $(wildcard ../Sources/InzoneDSP/*.swift)
DEBUG_OBJECT ?= debug.o
OUTPUT ?= inzone_dsp.so

.PHONY: all install
all: $(OUTPUT)
$(OUTPUT): $(SWIFT_SOURCES) $(DEBUG_OBJECT) ../Sources/CLADSPA/include/header.h ../Sources/CLADSPA/module.modulemap exports.map Makefile
	@mkdir -p "$(@D)"
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
	@mkdir -p "$(@D)"
	$(CC) -O2 -fPIC -I ../Sources/CLADSPA/include -c debug.c -o $@

PLUGIN_HASH = $(shell sha256sum "$(OUTPUT)" 2>/dev/null | cut -c1-16)
install: $(OUTPUT)
	install -d $(DESTDIR)/usr/lib/ladspa
	install -m 0755 "$(OUTPUT)" $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so.new
	mv $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so.new $(DESTDIR)/usr/lib/ladspa/inzone_dsp_$(PLUGIN_HASH).so
