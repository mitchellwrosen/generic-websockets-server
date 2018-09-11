.PHONY: build freeze install run

build:
	cabal new-build

freeze:
	rm -f cabal.project.freeze
	cabal new-freeze

install: build
	cp `cabal-plan list-bin generic-websockets-server` ~/.local/bin


run:
	cabal new-run generic-websockets-server -- 8080
