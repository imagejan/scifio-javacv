#!/bin/sh

if test $# != 2
then
	echo "Usage: $0 <platform> <target>" >&2
	exit 1
fi

PLATFORM=
case "$(uname -s)" in
Linux)
	if test "$(uname -m)" = i686
	then
		PLATFORM=linux
	else
		PLATFORM=linux64
	fi
	;;
Darwin)
	PLATFORM=macosx
	;;
MINGW*)
	PLATFORM=win32
	;;
esac

CONFIGURE_CROSS_COMPILE=
CROSS_PREFIX=
if test "$PLATFORM" != "$1"
then
	PLATFORM="$1"
	ARCH="$(case "$PLATFORM" in *64) echo x86_64;; *) echo i686;; esac)"
	# TODO: allow cross compilation of linux32, too
	TARGET_OS="$(case "$PLATFORM" in win*) echo mingw32;; esac)"
	CROSS_PREFIX=x86_64-w64-mingw32-
	CFLAGS="-m$(case "$PLATFORM" in *64) echo 64;; *) echo 32;; esac)"
	LDFLAGS="$CFLAGS"
	export CFLAGS LDFLAGS

	CONFIGURE_CROSS_COMPILE="--enable-cross-compile --cross-prefix=$CROSS_PREFIX --target-os=$TARGET_OS --arch=$ARCH"
fi

PLATFORM="$1"
TARGET="$2"
LIBPREFIX=${TARGET%ffmpeg.*}
LIBEXT=${TARGET#*ffmpeg}

PARALLEL=-j5

LDFLAGS=
EXTRA_CONFIGURE=
EXTRA_LDFLAGS=
EXTRA_LIBS=
NEED_LIPO=false
case "$PLATFORM" in
linux*)
	EXTRA_LDFLAGS="-Wl,-soname,libffmpeg.so -Wl,--warn-common -Wl,--as-needed -Wl,-Bsymbolic"
	;;
macosx)
	EXTRA_CONFIGURE="--disable-yasm --target-os=darwin --enable-cross-compile"
	EXTRA_LDFLAGS="-dynamiclib -Wl,-single_module -Wl,-install_name,libffmpeg.dylib,-compatibility_version,1 -Wl,-read_only_relocs,suppress"
	NEED_LIPO=true
	;;
win32)
	EXTRA_CONFIGURE="--enable-memalign-hack"
	EXTRA_LIBS="-lavicap32"
	;;
win64)
	EXTRA_CONFIGURE="--disable-avisynth"
	EXTRA_LIBS="-lavicap32"
	;;
esac

die () {
	echo "$*" >&2
	exit 1
}

# Go to working directory

cd "$(dirname "$0")" || die "Could not go to $(dirname "$0")"

# Make sure ffmpeg and libswscale are checked out at the correct revision

require_clean_working_directory () {
        git rev-parse --verify HEAD > /dev/null &&
        git update-index --ignore-submodules --refresh &&
        git diff-files --quiet --ignore-submodules &&
        git diff-index --cached --quiet HEAD --ignore-submodules -- ||
	die "Not clean: $(pwd)"
}

build_ffmpeg () {
	if test -f config.mak
	then
		make distclean || :
	fi &&
	echo "$CONFIGURE_CROSS_COMPILE" > .cross-compile &&
	./configure --enable-gpl --enable-shared $CONFIGURE_CROSS_COMPILE $EXTRA_CONFIGURE &&
	: SYMVER breaks our one-single-library approach
	sed 's/\( HAVE_SYMVER.*\) 1$/\1 0/' < config.h > config.h.new &&
	mv -f config.h.new config.h &&
	make $PARALLEL &&
	rm */*$LIBEXT* &&
	out="$(make V=1 | grep -ve '-o libavfilter' |
		sed -n 's/^'$CROSS_PREFIX'gcc .* -o lib[^ ]* //p' | tr ' ' '\n')" &&
	${CROSS_PREFIX}gcc -shared $LDFLAGS $EXTRA_LDFLAGS -o $1 \
		$(echo "$out" | grep -ve '^-' -e 'libavcodec/inverse\.o') \
		$(echo "$out" | grep '^-' | grep -ve '^-lav' -e '^-lsw' |
			sort | uniq) $EXTRA_LIBS
}

default_excludes="*.[oad] *.pc *$LIBEXT *$LIBEXT.[0-9] *$LIBEXT.[0-9][0-9] .config .version config.* *.ver /*_g /ffmpeg /ffplay /ffserver /ffprobe /version.h /libswscale/ /libavutil/avconfig.h"

pseudo_submodule_update () {
	path=$1
	url=$2
	revision=$3

	if test ! -d "$path"
	then
		git clone "$url" "$path"
	fi &&
	(cd "$path" &&
	 exclude_file="$(git rev-parse --git-dir)"/info/exclude &&
	 exclude="$(cat "$exclude_file" 2> /dev/null)" &&
	 required_excludes="$(echo "$default_excludes" | tr ' ' '\n')" &&
	 (echo "$exclude"; echo "$exclude"; echo "$required_excludes") |
		sort | uniq -u >> "$exclude_file" &&
	 require_clean_working_directory &&
	 if test "$revision" != "$(git rev-parse HEAD)"
	 then
		git checkout "$revision"
	 fi)
}

echo "Making sure that ffmpeg and libswscale are at correct revision" &&
pseudo_submodule_update ffmpeg \
	contrib@pacific.mpi-cbg.de:/srv/git/ffmpeg.git \
	90d23d8677612ee974261eacea53ca95de5c95a4 &&
pseudo_submodule_update ffmpeg/libswscale \
	contrib@pacific.mpi-cbg.de:/srv/git/libswscale.git \
	a88e950fe043e419d0f9e7f851d2d8e35aea2b83 &&

# Build FFMPEG

echo "Checking whether FFMPEG needs to be built" &&
(cd ffmpeg &&
 uptodate=true &&
 case "$(cat .cross-compile 2> /dev/null)" in
 "$CONFIGURE_CROSS_COMPILE") ;;
 *) uptodate=false;;
 esac &&
 if test ! -f $TARGET
 then
	uptodate=false
	break
 fi &&
 if test true = "$uptodate" &&
	test ! -z "$(eval find . -name '\\*.[ch]' -a -newer $TARGET)"
 then
	uptodate=false
 fi &&
 if test false = "$uptodate"
 then
	echo "Building FFMPEG" &&
	# make sure that everything is built from scratch
	case "$NEED_LIPO" in
	true)
		save="$EXTRA_CONFIGURE" &&
		for cpu in i386 x86_64
		do
			bits=${cpu#*86} &&
			bits=${bits#_} &&
			bits=${bits:-32} &&
			export CFLAGS="$CFLAGS -arch $cpu -m$bits" &&
			export LDFLAGS="$CFLAGS" &&
			build_ffmpeg lib$bits$LIBEXT || break
		done &&
		lipo -create lib32$LIBEXT lib64$LIBEXT -output $TARGET
		;;
	*)
		build_ffmpeg $TARGET
		;;
	esac
 fi)
