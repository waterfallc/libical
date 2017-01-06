#!/bin/sh

#Exit if any undefined variable is used.
set -u
#Exit this script if it any subprocess exits non-zero.
#set -e
#If any process in a pipeline fails, the return value is a failure.
set -o pipefail

#ensure parallel builds
export MAKEFLAGS=-j8

##### START FUNCTIONS #####

#function HELP
# print a help message and exit
HELP() {
  echo
  echo "Usage: `basename $0` [OPTIONS]"
  echo
  echo "Run build tests"
  echo "Options:"
  echo " -k, --no-krazy        Don't run any Krazy tests"
  echo " -c, --no-cppcheck     Don't run any cppcheck tests"
  echo " -t, --no-tidy         Don't run any clang-tidy tests"
  echo " -b, --no-scan         Don't run any scan-build tests"
  echo " -s, --no-splint       Don't run any splint tests"
  echo " -l, --no-clang-build  Don't run any clang-build tests"
  echo " -g, --no-gcc-build    Don't run any gcc-build tests"
  echo " -a, --no-asan-build   Don't run any ASAN-build tests"
  echo
}

#function SET_GCC
# setup compiling with gcc
SET_GCC() {
  export CC=gcc; export CXX=g++
}

#function SET_CLANG
# setup compiling with clang
SET_CLANG() {
  export CC=clang; export CXX=clang++
}

#function SET_BDIR:
# set the name of the build directory for the current test
# $1 = the name of the current test
SET_BDIR() {
  BDIR=$TOP/build-$1
}

#function CHECK_WARNINGS:
# print non-whitelisted warnings found in the file and exit if there are any
# $1 = file to check
# $2 = whitelist regex
CHECK_WARNINGS() {
  w=`cat $1 | grep warning: | grep -v "$2" | wc -l | awk '{print $1}'`
  if ( test $w -gt 0 )
  then
    echo "EXITING. $w warnings encountered"
    echo
    cat $1 | grep warning: | grep -v "$2"
    exit 1
  fi
}

#function COMPILE_WARNINGS:
# print warnings found in the compile-stage output
# $1 = file with the compile-stage output
COMPILE_WARNINGS() {
  whitelist='\(Value[[:space:]]descriptions\|g-ir-scanner:\|clang.*argument[[:space:]]unused[[:space:]]during[[:space:]]compilation\)'
  CHECK_WARNINGS $1 $whitelist
}

#function CPPCHECK_WARNINGS:
# print warnings found in the cppcheck output
# $1 = file with the cppcheck output
CPPCHECK_WARNINGS() {
  CHECK_WARNINGS $1 ""
}

#function TIDY_WARNINGS:
# print warnings find in the clang-tidy output
# $1 = file with the clang-tidy output
TIDY_WARNINGS() {
  whitelist='\(Value[[:space:]]descriptions\|g-ir-scanner:\|clang.*argument[[:space:]]unused[[:space:]]during[[:space:]]compilation\|modernize-\|cppcoreguidelines-pro-type-const-cast\|cppcoreguidelines-pro-type-reinterpret-cast\|cppcoreguidelines-pro-type-vararg\|cppcoreguidelines-pro-bounds-pointer-arithmetic\|google-build-using-namespace\|llvm-include-order\)'
  CHECK_WARNINGS $1 $whitelist
}

#function SCAN_WARNINGS:
# print warnings found in the scan-build output
# $1 = file with the scan-build output
SCAN_WARNINGS() {
  whitelist='\(Value[[:space:]]descriptions\|icalerror.*Dereference[[:space:]]of[[:space:]]null[[:space:]]pointer\|icalssyacc.*garbage[[:space:]]value\)'
  CHECK_WARNINGS $1 $whitelist
}

#function CONFIGURE:
# creates the builddir and runs CMake with the specified options
# $1 = the name of the test
# $2 = CMake options
CONFIGURE() {
  SET_BDIR $1
  mkdir -p $BDIR
  cd $BDIR
  rm -rf *
  cmake .. $2 || exit 1
}

#function CLEAN:
# remove the builddir
CLEAN() {
  cd $TOP
  rm -rf $BDIR
}

#function BUILD:
# runs a build test, where build means: configure, compile, link and run the unit tests
# $1 = the name of the test
# $2 = CMake options
BUILD() {
  cd $TOP
  CONFIGURE "$1" "$2"
  make |& tee make.out || exit 1
  COMPILE_WARNINGS make.out
  make test |& tee make-test.out || exit 1
  CLEAN
}

#function GCC_BUILD:
# runs a build test using gcc
# $1 = the name of the test (which will have "-gcc" appended to it)
# $2 = CMake options
GCC_BUILD() {
  name="$1-gcc"
  if ( test $rungccbuild -eq 0 )
  then
    echo "===== GCC BUILD TEST $1 DISABLED DUE TO COMMAND LINE OPTION ====="
    return
  fi
  echo "===== START GCC BUILD: $1 ======"
  SET_GCC
  BUILD "$name" "$2"
  echo "===== END GCC BUILD: $1 ======"
}

#function CLANG_BUILD:
# runs a build test using clang
# $1 = the name of the test (which will have "-clang" appended to it)
# $2 = CMake options
CLANG_BUILD() {
  name="$1-clang"
  if ( test $runclangbuild -eq 0 )
  then
    echo "===== CLANG BUILD TEST $1 DISABLED DUE TO COMMAND LINE OPTION ====="
    return
  fi
  echo "===== START CLANG BUILD: $1 ======"
  SET_CLANG
  BUILD "$name" "$2"
  echo "===== END CLANG BUILD: $1 ======"
}

#function ASAN_BUILD:
# runs an clang ASAN build test
# $1 = the name of the test (which will have "-asan" appended to it)
# $2 = CMake options
ASAN_BUILD() {
  name="$1-asan"
  if ( test $runasanbuild -eq 0 )
  then
    echo "===== ASAN BUILD TEST $1 DISABLED DUE TO COMMAND LINE OPTION ====="
    return
  fi
  echo "===== START ASAN BUILD: $1 ======"
  SET_CLANG
  BUILD "$name" "-DADDRESS_SANITIZER=True $2"
  echo "===== END ASAN BUILD: $1 ======"
}

#function CPPCHECK
# runs a cppcheck test, which means: configure, compile, link and run cppcheck
# $1 = the name of the test (which will have "-cppcheck" appended to it)
# $2 = CMake options
CPPCHECK() {
  name="$1-cppcheck"
  if ( test $runcppcheck -eq 0 )
  then
    echo "===== CPPCHECK TEST $1 DISABLED DUE TO COMMAND LINE OPTION ====="
    return
  fi
  echo "===== START SETUP FOR CPPCHECK: $1 ======"

  #first build it
  cd $TOP
  SET_GCC
  CONFIGURE "$name" "$2"
  make |& tee make.out || exit 1

  echo "===== START CPPCHECK: $1 ======"
  cd $TOP
  cppcheck --quiet --std=posix --language=c \
           --force --error-exitcode=1 --inline-suppr \
           --enable=warning,performance,portability,information \
           -D sleep="" \
           -D localtime_r="" \
           -D gmtime_r="" \
           -D size_t="unsigned long" \
           -D bswap32="" \
           -D PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP="" \
           -I $BDIR \
           -I $BDIR/src/libical \
           -I $BDIR/src/libicalss \
           -I $TOP/src/libical \
           -I $TOP/src/libicalss \
           -I $TOP/src/libicalvcal \
           $TOP/src $BDIR/src/libical/icalderived* 2>&1 | \
      grep -v 'Found a statement that begins with numeric constant' | \
      grep -v 'cannot find all the include files' | \
      grep -v Net-ICal | \
      grep -v icalssyacc\.c  | \
      grep -v icalsslexer\.c | tee cppcheck.out
  CPPCHECK_WARNINGS cppcheck.out
  rm -f cppcheck.out
  CLEAN
  echo "===== END CPPCHECK: $1 ======"
}

#function SPLINT
# runs a splint test, which means: configure, compile, link and run splint
# $1 = the name of the test (which will have "-splint" appended to it
# $2 = CMake options
SPLINT() {
  name="$1-splint"
  if ( test $runsplint -eq 0 )
  then
    echo "===== SPLIT TEST $1 DISABLED DUE TO COMMAND LINE OPTION ====="
    return
  fi
  echo "===== START SETUP FOR SPLINT: $1 ======"

  #first build it
  cd $TOP
  SET_GCC
  CONFIGURE "$name" "$2"
  make |& tee make.out || exit 1

  echo "===== START SPLINT: $1 ======"
  cd $TOP
  files=`find src -name "*.c" -o -name "*.h" | \
  # skip C++
  grep -v _cxx | grep -v /Net-ICal-Libical |
  # skip lex/yacc
  grep -v /icalssyacc | grep -v /icalsslexer | \
  # skip test programs
  grep -v /test/ | grep -v /vcaltest\.c | grep -v /vctest\.c | \
  # skip builddirs
  grep -v build-`
  files="$files $BDIR/src/libical/*.c $BDIR/src/libical/*.h"

  splint $files \
       -weak -warnposix \
       -modobserver -initallelements -redef \
       -linelen 1000 \
       -DHAVE_CONFIG_H=1 \
       -DPACKAGE_DATA_DIR="\"foo\"" \
       -DTEST_DATADIR="\"bar\"" \
       -D"gmtime_r"="" \
       -D"localtime_r"="" \
       -D"nanosleep"="" \
       -D"popen"="fopen" \
       -D"pclose"="" \
       -D"setenv"="" \
       -D"strdup"="" \
       -D"strcasecmp"="strcmp" \
       -D"strncasecmp"="strncmp" \
       -D"putenv"="" \
       -D"unsetenv"="" \
       -D"tzset()"=";" \
       -DLIBICAL_ICAL_EXPORT=extern \
       -DLIBICAL_ICALSS_EXPORT=extern \
       -DLIBICAL_VCAL_EXPORT=extern \
       -DLIBICAL_ICAL_NO_EXPORT="" \
       -DLIBICAL_ICALSS_NO_EXPORT="" \
       -DLIBICAL_VCAL_NO_EXPORT="" \
       -DENOENT=1 -DENOMEM=1 -DEINVAL=1 -DSIGALRM=1 \
       `pkg-config glib-2.0 --cflags` \
       `pkg-config libxml-2.0 --cflags` \
       -I $BDIR \
       -I $BDIR/src \
       -I $BDIR/src/libical \
       -I $BDIR/src/libicalss \
       -I $TOP \
       -I $TOP/src \
       -I $TOP/src/libical \
       -I $TOP/src/libicalss \
       -I $TOP/src/libicalvcal \
       -I $TOP/src/libical-glib | \
  cat - |& tee splint-$name.out
  status=${PIPESTATUS[0]}
  if ( test $status -gt 0 )
  then
    echo "Splint warnings encountered.  Exiting..."
    exit 1
  fi
  CLEAN
  rm splint-$name.out
  echo "===== END SPLINT: $1 ======"
}

#function CLANGTIDY
# runs a clang-tidy test, which means: configure, compile, link and run clang-tidy
# $1 = the name of the test (which will have "-tidy" appended)
# $2 = CMake options
CLANGTIDY() {
  if ( test $runtidy -eq 0 )
  then
    echo "===== CLANG-TIDY TEST $1 DISABLED DUE TO COMMAND LINE OPTION ====="
    return
  fi
  echo "===== START CLANG-TIDY: $1 ====="
  cd $TOP
  SET_CLANG
  CONFIGURE "$1-tidy" "$2 -DCMAKE_CXX_CLANG_TIDY=clang-tidy;-checks=*"
  cmake --build . |& tee make-tidy.out || exit 1
  TIDY_WARNINGS make-tidy.out
  CLEAN
  echo "===== END CLANG-TIDY: $1 ====="
}

#function CLANGSCAN
# runs a scan-build, which means: configure, compile and link using scan-build
# $1 = the name of the test (which will have "-scan" appended)
# $2 = CMake options
CLANGSCAN() {
  if ( test $runscan -eq 0 )
  then
    echo "===== SCAN-BUILD TEST $1 DISABLED DUE TO COMMAND LINE OPTION ====="
    return
  fi
  echo "===== START SCAN-BUILD: $1 ====="
  cd $TOP

  #configure specially with scan-build
  SET_BDIR "$1-scan"
  mkdir -p $BDIR
  cd $BDIR
  rm -rf *
  scan-build cmake .. "$2" || exit 1

  scan-build make |& tee make-scan.out || exit 1
  SCAN_WARNINGS make-scan.out
  CLEAN
  echo "===== END CLANG-SCAN: $1 ====="
}

#function KRAZY
# runs a krazy2 test
KRAZY() {
  if ( test $runkrazy -eq 0 )
  then
    echo "===== KRAZY TEST DISABLED DUE TO COMMAND LINE OPTION ====="
    return
  fi
  echo "===== START KRAZY ====="
  cd $TOP
  krazy2all |& tee krazy.out
  status=$?
  if ( test $status -gt 0 )
  then
    echo "Krazy warnings encountered.  Exiting..."
    exit 1
  fi
  rm -f krazy.out
  echo "===== END KRAZY ======"
}

##### END FUNCTIONS #####

TEMP=`getopt -o hkctbslga --long help,no-krazy,no-cppcheck,no-tidy,no-scan,no-splint,no-clang-build,no-gcc-build,no-asan-build -- "$@"`
if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi
# Note the quotes around `$TEMP': they are essential!
eval set -- "$TEMP"

runkrazy=1
runcppcheck=1
runtidy=1
runscan=1
runclangbuild=1
rungccbuild=1
runasanbuild=1
runsplint=1
while true ; do
    case "$1" in
        -h|--help) HELP; exit 1;;
        -k|--no-krazy)       runkrazy=0;      shift;;
        -c|--no-cppcheck)    runcppcheck=0;   shift;;
        -t|--no-tidy)        runtidy=0;       shift;;
        -b|--no-scan)        runscan=0;       shift;;
        -s|--no-splint)      runsplint=0;     shift;;
        -l|--no-clang-build) runclangbuild=0; shift;;
        -g|--no-gcc-build)   rungccbuild=0;   shift;;
        -a|--no-asan-build)  runasanbuild=0;       shift;;
        --) shift; break;;
        *)  echo "Internal error!"; exit 1;;
    esac
done

#MAIN
TOP=`dirname $0`
cd $TOP
cd ..
TOP=`pwd`
BDIR=""

CMAKEOPTS="-DCMAKE_BUILD_TYPE=Debug -DUSE_INTEROPERABLE_VTIMEZONES=True -DGOBJECT_INTROSPECTION=True -DICAL_GLIB=True"

#Static code checkers
KRAZY
SPLINT test2 "$CMAKEOPTS"
CPPCHECK test2 "$CMAKEOPTS"
CLANGSCAN test2 "$CMAKEOPTS"
CLANGTIDY test2 "$CMAKEOPTS"

#GCC based build tests
GCC_BUILD test1 ""
GCC_BUILD test2 "$CMAKEOPTS"
GCC_BUILD test1cross "-DCMAKE_TOOLCHAIN_FILE=$TOP/cmake/Toolchain-Linux-GCC-i686.cmake"
GCC_BUILD test2cross "-DCMAKE_TOOLCHAIN_FILE=$TOP/cmake/Toolchain-Linux-GCC-i686.cmake $CMAKEOPTS"

#Clang based build tests
CLANG_BUILD test1 ""
CLANG_BUILD test2 "$CMAKEOPTS"
CLANG_BUILD test1cross "-DCMAKE_TOOLCHAIN_FILE=$TOP/cmake/Toolchain-Linux-GCC-i686.cmake"
CLANG_BUILD test2cross "-DCMAKE_TOOLCHAIN_FILE=$TOP/cmake/Toolchain-Linux-GCC-i686.cmake $CMAKEOPTS"

#Address sanitizer
ASAN_BUILD test "-DUSE_INTEROPERABLE_VTIMEZONES=True"

echo "ALL TESTS COMPLETED SUCCESSFULLY"
