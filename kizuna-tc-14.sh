#!/usr/bin/env bash

# Import telegram specific environment
source "${HOME}/tools/scripts/env/local/telegram-chn/telegram_id_beta_env"

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# Set Chat ID, to push Notifications
CHATID=${TELEGRAM_GROUP_ID}

# Inlined function to post a message
# Telegram Bot Service || Compiling Notification
function bot_template() {
curl -s -X POST https://api.telegram.org/bot${TELEGRAM_BOT_ID}/sendMessage -d chat_id=${TELEGRAM_GROUP_ID} -d "parse_mode=HTML" -d text="$(
	for POST in "${@}";
		do
			echo "${POST}"
		done
	)"
}

# Build Info
rel_date="$(date "+%Y%m%d")" # ISO 8601 format
rel_friendly_date="$(date "+%B %-d, %Y")" # "Month day, year" format
builder_commit="$(git rev-parse HEAD)"

# Telegram Bot Service || Compiling Message
function bot_first_compile() {
	bot_template	"<b>|| HANA-CI Build Bot ||</b>" \
			"" \
			"<b>Kizuna Clang build start!</b>" \
			"" \
			"============= Build Information ================" \
			"<b>Build Date :</b><code> $rel_friendly_date </code>" \
			"<b>Toolchain Revision :</b><code> $builder_commit  </code>"
}

function bot_complete_compile() {
	bot_template	"<b>|| HANA-CI Build Bot ||</b>" \
			"" \
			"<b>New Kizuna Clang Build Is Available!</b>" \
			"" \
			"============ Build Information ================" \
			"<b>Build Date :</b><code> $rel_friendly_date </code>" \
			"<b>Toolchain Revision: </b><code> $builder_commit </code>" \
			"<b>Clang Version :</b><code> $clang_version </code>" \
   			"<b>Binutils Version :</b><code> $binutils_ver </code>" \
			"" \
			"<b>Compile Time :</b><code> $(($DIFF / 60)) minute(s) and $(($DIFF % 60)) second(s)</code>" \
			"<b>                         HANA-CI Build Project | 2016-2022                            </b>"
}

# Telegram bot message || failed notification
function bot_build_failed() {
	bot_template	"<b>|| HANA-CI Build Bot ||</b>" \
			"" \
			"<b>Kizuna Clang build failed!</b>" \
			"" \
			"<b>Compile Time :</b><code> $(($DIFF / 60)) minute(s) and $(($DIFF % 60)) second(s)</code>"
}

# Build LLVM
bot_first_compile
msg "Building LLVM..."
START=$(date +"%s")
./build-llvm.py \
	--clang-vendor "Kizuna" \
	--branch "release/14.x" \
	--defines LLVM_PARALLEL_COMPILE_JOBS=$(nproc) LLVM_PARALLEL_LINK_JOBS=$(nproc) \
	--lto thin \
	--incremental \
	--shallow-clone \
	--no-ccache \
	--pgo kernel-defconfig \
	--projects "clang;polly;lld" \
	--targets "ARM;AArch64;X86" 2>&1 | tee build.log

# Check if the final clang binary exists or not.
[ ! -f install/bin/clang-1* ] && {
	END=$(date +"%s")
	DIFF=$(($END - $START))
	bot_build_failed
	curl -F chat_id=${TELEGRAM_GROUP_ID} -F document="@build.log"  https://api.telegram.org/bot${TELEGRAM_BOT_ID}/sendDocument
	exit 1
}

# Build binutils
msg "Building binutils..."
if [ $(which clang) ] && [ $(which clang++) ]; then
	export CC=$(which ccache)" clang"
	export CXX=$(which ccache)" clang++"
	[ $(which llvm-strip) ] && stripBin=llvm-strip
else
	export CC=$(which ccache)" gcc"
	export CXX=$(which ccache)" g++"
	[ $(which strip) ] && stripBin=strip
fi

./build-binutils.py --targets arm aarch64 x86_64

# Remove unused products
msg "Removing unused products..."
rm -fr install/include
rm -f install/lib/*.a install/lib/*.la

msg "Setting library load paths for portability and"
msg "Stripping remaining products..."
IFS=$'\n'
for f in $(find install -type f -exec file {} \;); do
	if [ -n "$(echo $f | grep 'ELF .* interpreter')" ]; then
		i=$(echo $f | awk '{print $1}'); i=${i: : -1}
		# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
		if [ -d $(dirname $i)/../lib/ldscripts ]; then
			patchelf --set-rpath '$ORIGIN/../../lib:$ORIGIN/../lib' "$i"
		else
			if [ "$(patchelf --print-rpath $i)" != "\$ORIGIN/../../lib:\$ORIGIN/../lib" ]; then
				patchelf --set-rpath '$ORIGIN/../lib' "$i"
			fi
		fi
		# Strip remaining products
		if [ -n "$(echo $f | grep 'not stripped')" ]; then
			${stripBin} --strip-unneeded "$i"
		fi
	elif [ -n "$(echo $f | grep 'ELF .* relocatable')" ]; then
		if [ -n "$(echo $f | grep 'not stripped')" ]; then
			i=$(echo $f | awk '{print $1}');
			${stripBin} --strip-unneeded "${i: : -1}"
		fi
	else
		if [ -n "$(echo $f | grep 'not stripped')" ]; then
			i=$(echo $f | awk '{print $1}');
			${stripBin} --strip-all "${i: : -1}"
		fi
	fi
done

END=$(date +"%s")
DIFF=$($END - $START)

llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<< "$llvm_commit")"
llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"
binutils_ver="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
clang_version="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"

bot_complete_compile
curl -F chat_id=${TELEGRAM_GROUP_ID} -F document="@build.log"  https://api.telegram.org/bot${TELEGRAM_BOT_ID}/sendDocument
