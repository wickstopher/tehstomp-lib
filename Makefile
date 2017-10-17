
build:
	cabal build

docs:
	cabal haddock

install: build docs
	cabal install --enable-documentation

clean:
	rm -rf dist/
	
uninstall: clean
	ghc-pkg unregister tehstomp-lib

reinstall: uninstall install
