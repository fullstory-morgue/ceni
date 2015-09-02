#!/usr/bin/make -f

NAME  := ceni
SVG   := $(NAME).svg
SIZES := 16x16 22x22 32x32 48x48 64x64 128x128
ICONS := $(addsuffix .png,$(SIZES))

all: $(ICONS)

%.png:
	mkdir -p hicolor/$(@:.png=)/apps/
	$(RM) hicolor/$(@:.png=)/apps/$(NAME).png
	inkscape $(SVG) --without-gui \
		--export-width=$(word 1,$(subst x, ,$(@:.png=)))  \
	        --export-height=$(word 2,$(subst x, ,$(@:.png=))) \
		--export-png=hicolor/$(@:.png=)/apps/$(NAME).png
