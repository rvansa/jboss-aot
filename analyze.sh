#!/bin/bash
# This script expects output from JVM unified logging, without decorations:

tr -s ' ' < /tmp/aot.txt | cut -f 2 -d ' ' | sort > /tmp/aot.filtered

#/opt/jdk-9/bin/java -cp $HOME/aot FilterClasses /tmp/class.txt | sort > /tmp/class.filtered
cut -f 1 -d ' ' < /tmp/class.txt | sort > /tmp/class.filtered

echo "Not AOTed:"
diff --unchanged-line-format= --old-line-format= --new-line-format=%L /tmp/aot.filtered /tmp/class.filtered

echo "Not loaded?"
diff --unchanged-line-format= --old-line-format=%L --new-line-format= /tmp/aot.filtered /tmp/class.filtered

