#!/bin/bash -e
# Place at: buildscripts/scripts/dovi.sh  (in your libmpv-android fork)
#
# Builds libdovi (the Dolby Vision RPU parser from quietvoid/dovi_tool) with
# cargo-c, so libplacebo's -Dlibdovi can reshape Dolby Vision (Profile 5/8).
# Installs libdovi.a + dovi.pc into the per-ABI prefix that libplacebo consumes
# via pkg-config. build.sh runs this with cwd = deps/dovi.

. ../../include/depinfo.sh
. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf dolby_vision/target
	exit 0
else
	exit 255
fi

# cc_triple (incl. API level, e.g. aarch64-linux-android26) comes from $CC,
# which build.sh's loadarch exports as "$cc_triple-clang".
cc_triple=${CC%-clang}

# Map the NDK triple to the matching Rust target (only armv7 differs).
case "$ndk_triple" in
	arm-linux-androideabi) rust_target=armv7-linux-androideabi ;;
	*)                     rust_target=$ndk_triple ;;
esac

rust_target_env=${rust_target//-/_}
rust_target_upper=$(echo "$rust_target_env" | tr '[:lower:]' '[:upper:]')

# Point cargo + the cc crate at the NDK clang/ar for this ABI.
export CARGO_TARGET_${rust_target_upper}_LINKER=$cc_triple-clang
export CC_${rust_target_env}=$cc_triple-clang
export CXX_${rust_target_env}=$cc_triple-clang++
export AR_${rust_target_env}=llvm-ar

rustup target add "$rust_target" >/dev/null 2>&1 || true

cd dolby_vision

# staticlib → libdovi.a is bundled into libmpv.so at the final link.
# --prefix=/usr matches the flat prefix symlinks (usr -> .), so dovi.pc lands in
# $prefix_dir/lib/pkgconfig where PKG_CONFIG_LIBDIR points.
cargo cinstall --release \
	--target "$rust_target" \
	--library-type staticlib \
	--prefix=/usr \
	--destdir "$prefix_dir"
