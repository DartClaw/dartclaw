.PHONY: build test analyze format check clean

build:
	bash tool/build.sh

test:
	dart test

analyze:
	dart analyze --fatal-infos

format:
	dart format --output=none --set-exit-if-changed .

check:
	$(MAKE) format
	$(MAKE) analyze
	$(MAKE) test

clean:
	rm -rf build/
