# Build the native panel and run the end-to-end check.
SOURCES = $(wildcard native/*.swift)

native/panel: $(SOURCES)
	swiftc -O $(SOURCES) -o $@

test: native/panel
	node test.mjs

clean:
	rm -f native/panel

.PHONY: test clean
