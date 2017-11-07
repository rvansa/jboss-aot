#!/bin/bash

JAVA_HOME=/opt/jdk-9

$JAVA_HOME/bin/jcmd $1 VM.print_touched_methods | awk -F: -v OFS='' '{ cls = gsub(/\//, ".", $1); print "compileOnly " $0 }' | tail -n +3
