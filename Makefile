
build:
	cabal build

install:
	cabal install

clean:
	rm -rf dist/
	
uninstall: clean
	ghc-pkg unregister tehstomp-lib
