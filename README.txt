# JBoss appserver (EAP/WildFly) AOT helper scripts
The purpose of this project is compiling and running JBoss appservers (EAP/WildFly) with JDK9's AOT support

## Scripts:
* compile.sh : generate *.so library files
* analyze.sh : check class-loading/aot-loading logs and verify if the used classes are AOTed

## Structure:
* $VERSION/lib/lib*.so : generated ELF files
* $VERSION/mock/$MODULE   : list of classes that need to be mocked
* $VERSION/commands/$MODULE : compile commands for jaotc
* $VERSION/deps/$MODULE : extra dependcies (non-transitive)
* $VERSION/props/$MODULE : system properties passed during compilation

## Compilation:
1. Setup `JBOSS_HOME` and `VERSION` environment variables
2. Run `./compile.sh` which populates `$VERSION/lib` directory
3. The script halts if there's any error or even output to stderr (e.g. `System.err.println()` in a static constructor). After checking the output the compilation should resume.
4. If jaotc emits "Failed compilation" error you need to fix it, or ignore it using `$VERSION/commands/$MODULE` list. Ignore-errors list is automatically generated to `$VERSION/commands/$MODULE.suggestion` but you should verify that you want to ignore the problems rather than fix it.
5. Some common errors can be autofixed adjusting mock/ or deps/. To attempt to do so run `./compile.sh --fix`
