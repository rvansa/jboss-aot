#!/bin/bash
trap "exit" INT
AOT=$(dirname $0)

# All the steps can take a while, let's make them optional
if [ -z "$1" ]; then
   STEPS="muzc"
else
   STEPS="$1"
fi

if [ -z "$JBOSS_HOME" ]; then
   JBOSS_HOME=$HOME/runtime/jboss-eap-7.1.0.CR2-jdk9
fi
if [ -z "$VERSION" ]; then
   VERSION=eap71
fi

PREFIXED_OPTS=""
for OPT in $JAVA_OPTS; do
   PREFIXED_OPTS="$PREFIXED_OPTS -J$OPT"
done;

#ALLDIR=$(mktemp -d --tmpdir "tmp.XXXX")
ALLDIR=/tmp/tmp.ABCD
mkdir -p $ALLDIR
ALLJAR=$ALLDIR.jar
ALLDEPS=`find $JBOSS_HOME -iname "*.jar" | tr '\n' ':'`

if [[ $STEPS == *m* ]]; then
   echo "Create mocks..."
   SOURCES=""
   MOCK_DEPS=$ALLDIR.mock
   mkdir -p $MOCK_DEPS
   for MODULE in `find $AOT/$VERSION/mock -type f`; do
   # Create missing class files and add the directory to dependencies
      while read -r LINE || [[ -n $LINE ]]; do
         if [[ $LINE == \#* || -z "$LINE" ]]; then continue; fi;
         PACKAGE=$(echo $LINE | sed 's/^\([^. ]* \)*\([^ ]*\)\..*/\2/')
         TYPE=$(echo $LINE | sed 's/^\([a-z ]*\) [a-z_]*\..*/\1/')
         CLASSNAME=$(echo $LINE | sed 's/\([^. ]* \)*[a-z_][^ ]*\.\([^ .]*\).*/\2/')
         EXTRA=$(echo $LINE | sed 's/^[^.]*[^ ]*//')
         PKG_DIR=$MOCK_DEPS/$(echo $PACKAGE | tr '.' '/')
         mkdir -p $PKG_DIR
         SOURCE=$PKG_DIR/$CLASSNAME.java
         if [ -f $SOURCE ]; then continue; fi
# Allow optional definition of a body in the 
         if [[ $EXTRA != *}* ]]; then EXTRA="$EXTRA {}"; fi
         echo "package $PACKAGE; public $TYPE $CLASSNAME $EXTRA" > $SOURCE
         SOURCES="$SOURCES $SOURCE"
      done < $MODULE
   done
   if [ -n "$SOURCES" ]; then
      javac -cp $ALLDEPS -d $ALLDIR $SOURCES || exit 1
   fi
fi

if [[ $STEPS == *u* ]]; then
   echo "Unzipping modules..."
   unzip -q -o $JBOSS_HOME/jboss-modules.jar -d $ALLDIR
   for JAR in `find $JBOSS_HOME -ipath "*/main/*.jar"`; do
      unzip -q -o $JAR -d $ALLDIR
   done;
   find $ALLDIR -type f -iname '*.sf' -delete -or -iname '*.rsa' -delete -or -iname '*.dsa' -delete
   find $ALLDIR -type f -ipath '*/META-INF/*.class' -delete
fi

if [[ $STEPS == *z* ]]; then
   echo "Zipping fat jar..."
   rm $ALLJAR
   CURRENT_DIR=`pwd`
   cd $ALLDIR
   zip -q -r $ALLJAR *
   cd $CURRENT_DIR
fi

#COMMANDS=$ALLDIR.cmds
COMMANDS=/tmp/compileOnly
#rm $COMMANDS
# Omit hidden & suggested files
#for CMDS in `find $AOT/$VERSION/commands -type f -not -name ".*" -not -name "*suggested"`; do
#   echo "# From $CMDS" >> $COMMANDS
#   cat $CMDS >> $COMMANDS
#done

#rm -rf $ALLDIR $MOCK_DEPS
echo $ALLJAR

for PROP in `cat $AOT/$VERSION/props/* | sort -u`; do
   PREFIXED_OPTS="$PREFIXED_OPTS -J-D$PROP"
done

if [[ $STEPS == *d* ]]; then
   PREFIXED_OPTS="$PREFIXED_OPTS -J-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=0.0.0.0:5005"
fi

/opt/oracle-jdk-9/bin/jaotc --jar $ALLJAR -J-cp -J$ALLJAR $PREFIXED_OPTS --output /tmp/lib$VERSION.so --info --compile-commands $COMMANDS --compile-threads 16

#rm $COMMANDS
