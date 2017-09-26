#!/bin/bash
trap "exit" INT
AOT=$(dirname $0)

if [ -z "$JBOSS_HOME" ]; then
   JBOSS_HOME=$HOME/runtime/jboss-eap-7.1-jdk9
fi
if [ -z "$VERSION" ]; then
   VERSION=eap71
fi
if [ -z "$JAVA_OPTS" ]; then
   JAVA_OPTS="-XX:+UseCompressedOops"
fi
if [ -z "$LOGLEVEL" ]; then
   LOGLEVEL="--info"
else
# When LOGLEVEL is set to --debug we appreciate non-interleaved error messages
   COMPILE_THREADS="--compile-threads 1"
fi

PREFIXED_OPTS=""
for OPT in $JAVA_OPTS; do
   PREFIXED_OPTS="$PREFIXED_OPTS -J$OPT"
done;

# Find module dependencies
dependencies() {
   local MODULE_XML=$1
   local PROCESSED=$2
   local DEPS=""
   if [ ! -f $MODULE_XML ]; then return; fi
   if grep -Fxq $MODULE_XML $PROCESSED ; then return; fi
   >&2 echo -n "."
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

# Add a dependency or create a mock class
# Note: This is used only when generating the required files
needs_class() {
   CLASSNAME=$1
   MODULE=`sed -n "s/$CLASSNAME .*layers\/base\/\(.*\)\/[^/]*\/[^/]*jar/\1/p" $AOT/eap.txt | tr '/' '.'`
   echo "Missing $CLASSNAME in $NAME, found? $MODULE"
   if [ -n "$MODULE" ]; then
      if grep $MODULE' *$' $AOT/$VERSION/deps/$NAME; then
         echo "Alread have a dependency to $MODULE";
      else
         echo +$MODULE >> $AOT/$VERSION/deps/$NAME
         echo "Adding dependency to $MODULE";
      fi
   elif [ -f $AOT/$VERSION/mock/$NAME ] && grep -e ' '$CLASSNAME'\( \|$\)' $AOT/$VERSION/mock/$NAME; then
      echo "Already have a mock!"
   elif [[ $CLASSNAME == *Exception ]]; then
      echo "class $CLASSNAME extends Exception" >> $AOT/$VERSION/mock/$NAME
   elif [[ $CLASSNAME == *Impl || $CLASSNAME == *Abstract* || $CLASSNAME == *Base* ]]; then
      echo "class $CLASSNAME" >> $AOT/$VERSION/mock/$NAME;
   else
      echo "interface $CLASSNAME" >> $AOT/$VERSION/mock/$NAME;
   fi
}

# Prepare the class -> JAR mapping
if [ ! -f $AOT/$VERSION/classes.txt ]; then
   echo "Creating class -> module mapping"
   for JAR in `find runtime/jboss-eap-7.1-jdk9/ -iname '*.jar'`; do
      for CLASS in `zipinfo -1 $JAR | sed -n 's/\.class$//p' | tr '/' '.'`; do
         echo $CLASS $JAR >> $AOT/$VERSION/classes.txt;
      done;
   done;
fi

MODULE_COUNTER=0
MODULE_TOTAL=`find $JBOSS_HOME/modules -iname 'module.xml' -printf . | wc -c`
for MODULE_XML in `find $JBOSS_HOME/modules -iname 'module.xml'`; do
   NAME=`sed -n 's/^<module.*name="\([^"]*\).*/\1/p' < $MODULE_XML`
   MODULE_COUNTER=$(($MODULE_COUNTER + 1))
   if [ -f $AOT/$VERSION/lib/lib$NAME.so ]; then
      echo -e "\n\n--- Skipping $NAME (library exists) $MODULE_COUNTER/$MODULE_TOTAL---"
      continue;
   fi
   JARS=""
   CLEANUP=""
# Get compiled jars (resources)
# If there are multiple jars in one module, when compiling one jar we won't see the others on classpath
   DEPS="$JBOSS_HOME/jboss-modules.jar"
   for JAR in `find $(dirname $MODULE_XML) -iname '*.jar'`; do
      if zipinfo -1 $JAR | grep -e 'META-INF.*class$' > /dev/null 2> /dev/null; then
         JAR_COPY=$(mktemp --tmpdir "tmp.XXXXXXXX.jar")
         cp $JAR $JAR_COPY
         for CLASS in `zipinfo -1 $JAR | grep -e 'META-INF.*class$'`; do
            zip -q -d $JAR_COPY $CLASS 
         done
         JAR=$JAR_COPY
         CLEANUP="$CLEANUP $JAR_COPY"
      fi
      JARS="$JARS --jar $JAR"
      DEPS="$DEPS:$JAR"
   done
   if [ -z "$JARS" ]; then
      echo -e "\n\n--- Skipping $NAME (nothing to compile) $MODULE_COUNTER/$MODULE_TOTAL ---"
      continue;
   fi
   echo -e "\n\n--- Compiling $NAME ($MODULE_XML) $MODULE_COUNTER/$MODULE_TOTAL ---"
   echo -n "Analyzing dependencies"
# Prevent cycles in dependencies by storing processed modules
   PROCESSED=$(mktemp --tmpdir "tmp.$NAME.deps.XXXX")
   CLEANUP="$CLEANUP $PROCESSED"
# Add explicit dependencies
   if [ -f $AOT/$VERSION/deps/$NAME ]; then
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
      done < <(sed 's/^ *\(.\)/\1 /' < $AOT/$VERSION/deps/$NAME)
   fi
   DEPS="$DEPS:$(dependencies $MODULE_XML $PROCESSED)"
# Create missing class files and add the directory to dependencies
   echo -e "\nCreating mock classes..."
   MOCK_DEPS=""
   if [ -f $AOT/$VERSION/mock/$NAME ]; then
      MOCK_DEPS=$(mktemp -d --tmpdir "tmp.$NAME.mock.XXXX")
      SOURCES=""
      while read -r LINE || [[ -n $LINE ]]; do
         if [[ $LINE == \#* || -z "$LINE" ]]; then continue; fi;
         PACKAGE=$(echo $LINE | sed 's/^\([^. ]* \)*\([^ ]*\)\..*/\2/')
         TYPE=$(echo $LINE | sed 's/^\([a-z ]*\) [a-z_]*\..*/\1/')
         CLASSNAME=$(echo $LINE | sed 's/\([^. ]* \)*[a-z_][^ ]*\.\([^ .]*\).*/\2/')
         EXTRA=$(echo $LINE | sed 's/^[^.]*[^ ]*//')
         PKG_DIR=$MOCK_DEPS/$(echo $PACKAGE | tr '.' '/')
         mkdir -p $PKG_DIR
         SOURCE=$PKG_DIR/$CLASSNAME.java
# Allow optional definition of a body in the 
         if [[ $EXTRA != *}* ]]; then EXTRA="$EXTRA {}"; fi
         echo "package $PACKAGE; public $TYPE $CLASSNAME $EXTRA" > $SOURCE
         SOURCES="$SOURCES $SOURCE"
      done < $AOT/$VERSION/mock/$NAME
      if [ -n "$SOURCES" ]; then
         javac -cp $DEPS -d $MOCK_DEPS $SOURCES || exit 1
      fi
      DEPS="$DEPS:$MOCK_DEPS"
      CLEANUP="$CLEANUP $MOCK_DEPS"
   fi
# Add custom properties required e.g. by static constructors
   PROPS=""
   if [ -f $AOT/$VERSION/props/$NAME ]; then
      for PROP in `cat $AOT/$VERSION/props/$NAME`; do
	if [[ $PROP == \#* ]]; then continue; fi;
	PROPS="$PROPS -J-D$PROP"
      done
      DEPS="$DEPS:$MOCK_DEPS"
   fi

# Assemble the compile command
   COMPILE="/opt/jdk-9/bin/jaotc $PREFIXED_OPTS $JARS --output $AOT/$VERSION/lib/lib$NAME.so $LOGLEVEL $COMPILE_THREADS --compile-for-tiered $PROPS"
   if [ -f $AOT/$VERSION/commands/$NAME ]; then
      COMPILE="$COMPILE --compile-commands $AOT/$VERSION/commands/$NAME"
   fi
   if [ -n "$DEPS" ]; then
	COMPILE="$COMPILE -J-cp -J$DEPS"
   fi
   echo "$COMPILE" > /tmp/$NAME.cmd
   bash -c "$COMPILE" 2> /tmp/$NAME.err | tee /tmp/$NAME.out
# Print out errors separately
   cat /tmp/$NAME.err
   if [ -n "$CLEANUP" ]; then rm -rf $CLEANUP; fi
# The code below automatically tries to fix common errors (with --fix argument)
   if grep "Failed compilation" /tmp/$NAME.out > /dev/null; then
      rm $AOT/$VERSION/lib/lib$NAME.so      
      sed -n 's/.*Failed compilation: \([^:]*\).*/exclude \1/p' /tmp/$NAME.out > $AOT/commands/$NAME.suggested     
      echo "Exclude suggestions: " $NAME.suggested
      if [ "$1" == "--fix" ]; then exit 1; fi
      for CLASSNAME in `sed -n '/Could not initialize/d;s/.*\(ClassNotFoundException\|NoClassDefFoundError\): //p' /tmp/$NAME.out | tr '/' '.'`; do
         needs_class $CLASSNAME
      done
      exit 1
   fi
   if [ -s /tmp/$NAME.err ]; then     
      read LINE < /tmp/$NAME.err
      if [[ $LINE == WARNING* ]]; then continue; fi
      CLASSNAME=`sed -n -e 's/.*ClassDefFoundError: \(.*\)/\1/p' < /tmp/$NAME.err | tr '/' '.' | head -n 1`
      if [ -z "$CLASSNAME" ]; then exit 1; fi;
      if [ "$1" == "--fix" ]; then exit 1; fi
      needs_class $CLASSNAME
      $AOT/compile.sh $1
      exit 1
   fi
done
