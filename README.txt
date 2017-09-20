The purpose of this project is compiling and running JBoss appservers (EAP/WildFly) with JDK9's AOT support

Scripts:
* compile.sh : generate *.so library files
* analyze.sh : check class-loading/aot-loading logs and verify if the used classes are AOTed

Structure:
* lib*.so : generated ELF files
* dummy/_module_   : list of classes that need to be mocked
* exclude/_module_ : compile commands for jaotc
* deps/_module_ : extra dependcies (non-transitive)
