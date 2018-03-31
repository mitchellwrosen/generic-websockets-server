.PHONY: build
build:
	cabal new-build

.PHONY: run
run:
	cabal new-run generic-websockets-server -- 8080
