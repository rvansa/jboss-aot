#!/bin/bash
JBOSS_HOME=$HOME/runtime/jboss-eap-7.1-jdk9
#set -e

if [ -n "$JAVA_OPTS" ]; then
   JAVA_OPTS="-XX:-UseCompressedOops"
fi

# Find module dependencies
dependencies() {
   local MODULE_XML=$1
   local PROCESSED=$2
   local DEPS=""
   if [ ! -f $MODULE_XML ]; then return; fi
   if grep -Fxq $MODULE_XML $PROCESSED ; then return; fi
   >&2 echo "$3 Analyze $1"
   echo $MODULE_XML >> $PROCESSED
   local JARS=`find $(dirname $MODULE_XML) -iname '*.jar' | tr '\n' ':'`
   if [ -n "$JARS" ]; then DEPS="$DEPS:$JARS"; fi
   while read -r MODULE SLOT || [[ -n $MODULE ]]; do
      if [ -z "$SLOT" ]; then
         SLOT="main"
      fi
      MODULE=$(echo $MODULE | tr '.' '/')
      DEPS="$DEPS$(dependencies $JBOSS_HOME/modules/system/layers/base/$MODULE/$SLOT/module.xml $PROCESSED '.'$3)"
   done < <(sed -n -e '/optional/d;s/.*module name="\([^"]*\)" *\(slot="\([^"]*\)"\)\{0,1\}.*/\1 \3/p' < $MODULE_XML)
   echo "$DEPS"
}

for MODULE_XML in `find $JBOSS_HOME/modules -iname 'module.xml'`; do
   NAME=`sed -n 's/^<module.*name="\([^"]*\).*/\1/p' < $MODULE_XML`
   if [ -f aot/lib$NAME.so ]; then
      echo -e "\n\n--- Skipping $NAME (library exists) ---"
      continue;
   fi
# Get compiled jars (resources)
   JARS=""
# If there are multiple jars in one module, when compiling one jar we won't see the others on classpath
   DEPS="$JBOSS_HOME/jboss-modules.jar"
# Prevent cycles in dependencies by storing processed modules
   PROCESSED=$(mktemp)
   for JAR in `find $(dirname $MODULE_XML) -iname '*.jar'`; do
      JARS="$JARS --jar $JAR"
      DEPS="$DEPS:$JAR"
   done
   if [ -z "$JARS" ]; then
      echo -e "\n\n--- Skipping $NAME (nothing to compile)"
      continue;
   fi
   echo -e "\n\n--- Compiling $NAME ---"
# Add explicit dependencies
   if [ -f aot/deps/$NAME ]; then
      while read -r CMD MODULE || [[ -n $MODULE ]]; do
        MODULE=$(echo $MODULE | tr '.' '/')
        if [ "$CMD" == "#" ]; then
           continue;
        elif [ "$CMD" == "+" ]; then
	   DEPS="$DEPS:$(find $JBOSS_HOME/modules/system/layers/base/$MODULE/main -iname '*jar' | tr '\n' ':')"
        elif [ "$CMD" != "-" ]; then
           >&2 echo "Unknown prefix $CMD for $MODULE"
           exit 1 
	fi          
        echo "$JBOSS_HOME/modules/system/layers/base/$MODULE/main/module.xml" >> $PROCESSED;
      done < <(sed 's/^ *\(.\)/\1 /' < aot/deps/$NAME)
   fi
   DEPS="$DEPS:$(dependencies $MODULE_XML $PROCESSED)"
   rm $PROCESSED
# Create missing class files and add the directory to dependencies
   DUMMY_DEPS=""
   if [ -f aot/dummy/$NAME ]; then
      DUMMY_DEPS=$(mktemp -d)
      SOURCES=""
      while read -r TYPE CLASSNAME EXTRA || [[ -n $CLASSNAME ]]; do
	if [[ $TYPE == \#* || -z "$TYPE" ]]; then continue; fi;
	PACKAGE=$(echo $CLASSNAME | sed 's/\.[^.]*$//')
	CLASSNAME=$(echo $CLASSNAME | sed 's/.*\.\([^.]*\)$/\1/')
	SOURCE=$DUMMY_DEPS/$CLASSNAME.java
	mkdir -p $DUMMY_DEPS/$(echo $PACKAGE | tr '.' '/')
	echo "package $PACKAGE; public $TYPE $CLASSNAME $EXTRA {}" > $SOURCE
        SOURCES="$SOURCES $SOURCE"
      done < aot/dummy/$NAME
      javac -cp $DEPS -d $DUMMY_DEPS $SOURCES
      DEPS="$DEPS:$DUMMY_DEPS"
   fi
# Add custom properties required e.g. by static constructors
   PROPS=""
   if [ -f aot/props/$NAME ]; then
      for PROP in `cat aot/props/$NAME`; do
	if [[ $PROP == \#* ]]; then continue; fi;
	PROPS="$PROPS -J-D$PROP"
      done
      DEPS="$DEPS:$DUMMY_DEPS"
   fi

# Assemble the compile command
   COMPILE="/opt/jdk-9/bin/jaotc $JAVA_OPTS $JARS --output aot/lib$NAME.so --info --compile-for-tiered $PROPS"
   if [ -f aot/exclude/$NAME ]; then
      COMPILE="$COMPILE --compile-commands aot/exclude/$NAME"
   fi
   if [ -n "$DEPS" ]; then
	COMPILE="$COMPILE -J-cp -J$DEPS"
   fi
   echo "$COMPILE"
   bash -c "$COMPILE" 2> /tmp/$NAME.err | tee /tmp/$NAME.out
   cat /tmp/$NAME.err
   if [ -s /tmp/$NAME.err ]; then     
      #rm aot/lib$NAME.so
      CLASSNAME=`sed -n -e 's/.*ClassDefFoundError: \(.*\)/\1/p' < /tmp/$NAME.err | tr '/' '.' | head -n 1`
      if [ -z "$CLASSNAME" ]; then exit 1; fi;
      echo "Missing $CLASSNAME in $NAME"
      grep "$CLASSNAME" aot/eap.txt
#      echo "$DEPS" | tr -s ':' '\n'
      # Do not add by default
      if [ -z "$1" ]; then exit 1; fi;
      if [[ $CLASSNAME == *Exception ]]; then
         echo "class $CLASSNAME extends Exception" >> aot/dummy/$NAME
      else
         echo "interface $CLASSNAME" >> aot/dummy/$NAME;
      fi
      exit 1
   fi
   if [ -n "$DUMMY_DEPS" ]; then rm -rf $DUMMY_DEPS; fi
done
