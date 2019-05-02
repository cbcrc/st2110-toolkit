#!/bin/bash
#
# Compile & Install everything for FFMPEG transcoding
# and tcpdump capturing

set -euo pipefail

THIS_DIR="$(dirname ${BASH_SOURCE[0]})"

if [ -f /etc/lsb-release ]; then
    OS=debian
    PACKAGE_MANAGER=apt
elif [ -f /etc/redhat-release ]; then
    OS=redhat
    PACKAGE_MANAGER=yum
else
    echo "Couldn't detect OS."
    exit 1
fi

export LANG=en_US.utf8 \
    LC_ALL=en_US.utf8 \
    FDKAAC_VERSION=0.1.4 \
    YASM_VERSION=1.3.0 \
    NASM_VERSION=2.13.02 \
    MP3_VERSION=3.99.5 \
    SMCROUTE_VERSION=2.4.3 \
    PREFIX=/usr/local \
    MAKEFLAGS="-j$[$(nproc) + 1]"

export PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig \

echo "${PREFIX}/lib" >/etc/ld.so.conf.d/libc.conf

install_common_tools()
{
    $PACKAGE_MANAGER -y update && $PACKAGE_MANAGER install -y \
        autoconf \
        automake \
        bzip2 \
        cmake \
        ethtool \
        gcc \
        git \
        libtool \
        linuxptp \
        make \
        net-tools \
        patch \
        perl \
        tar \
        tcpdump \
        tmux \
        wget

    if [ $OS = "redhat" ]; then
        $PACKAGE_MANAGER -y update && $PACKAGE_MANAGER install -y \
            nc \
            gcc-c++ \
            openssl-devel \
            which \
            zlib-devel
    fi
}

install_monitoring_tools()
{
    if [ $OS = "redhat" ]; then
        wget dl.fedoraproject.org/pub/epel/7/x86_64/Packages/e/epel-release-7-11.noarch.rpm
        rpm -ihv epel-release-7-11.noarch.rpm
    fi

    $PACKAGE_MANAGER -y install \
        htop \
        nload \
        vim \
        tig \
        psmisc
}

install_yasm()
{
    echo "Installing YASM"
    DIR=$(mktemp -d)
    cd $DIR/
    curl -s http://www.tortall.net/projects/yasm/releases/yasm-$YASM_VERSION.tar.gz |
        tar zxvf - -C .
    cd $DIR/yasm-$YASM_VERSION/
    ./configure --prefix="$PREFIX" --bindir="$PREFIX/bin" --docdir=$DIR -mandir=$DIR
    make
    make install
    make distclean
    rm -rf $DIR
}

install_nasm()
{
    echo "Installing NASM"
    if [ $OS = "redhat" ]; then
        DIR=$(mktemp -d)
        cd $DIR/
        nasm_rpm=nasm-$NASM_VERSION-0.fc24.x86_64.rpm
        curl -O https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VERSION/linux/$nasm_rpm
        rpm -i $nasm_rpm
        rm -f $nasm_rpm
        rm -rf $DIR
    else
        $PACKAGE_MANAGER -y install nasm
    fi
}

install_x264()
{
    echo "Installing x264"
    DIR=$(mktemp -d)
    cd $DIR/
    git clone -b stable  --single-branch http://git.videolan.org/git/x264.git
    cd x264/
    ./configure --prefix="$PREFIX" --bindir="$PREFIX/bin" --enable-static
    make
    make install
    make distclean
    rm -rf $DIR
    # or both install libx264.XXX and libx264-dev from distro packages
}

install_fdkaac()
{
    echo "Installing fdk-aac"
    DIR=$(mktemp -d)
    cd $DIR/
    curl -s https://codeload.github.com/mstorsjo/fdk-aac/tar.gz/v$FDKAAC_VERSION |
        tar zxvf - -C .
    cd fdk-aac-$FDKAAC_VERSION/
    autoreconf -fiv
    ./configure --prefix="$PREFIX" --disable-shared
    make
    make install
    make distclean
    rm -rf $DIR
}

install_mp3()
{
    echo "Installing mp3"
    DIR=$(mktemp -d)
    cd $DIR/
    curl -s -L http://downloads.sourceforge.net/project/lame/lame/3.99/lame-$MP3_VERSION.tar.gz |
        tar zxvf - -C .
    cd lame-$MP3_VERSION/
    ./configure --prefix="$PREFIX" --bindir="$PREFIX/bin" --disable-shared --enable-nasm
    make
    make install
    make distclean
    rm -rf $DIR
}

install_ffnvcodec()
{
    echo "Installing ffnvcodev"
    DIR=$(mktemp -d)
    cd $DIR/
    git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git
    cd nv-codec-headers
    make
    make install
    make distclean
    rm -rf $DIR
    # provide new option to ffmpeg
    ffmpeg_gpu_options="--enable-cuda --enable-cuvid --enable-nvenc --enable-libnpp --extra-cflags=-I$PREFIX/cuda/include --extra-ldflags=-L$PREFIX/cuda/lib64"
}

install_ffmpeg()
{
    echo "Installing ffmpeg"
    DIR=$(mktemp -d)
    cd $DIR/
    git clone https://github.com/cbcrc/FFmpeg.git
    cd FFmpeg
    git checkout SMPTE2110/master

    ./configure --prefix=$PREFIX \
        --extra-cflags=-I$PREFIX/include \
        --extra-ldflags=-L$PREFIX/lib \
        --bindir=$PREFIX/bin \
        --extra-libs=-ldl \
        --enable-version3 --enable-gpl --enable-nonfree \
        --enable-postproc --enable-avresample \
        --enable-libx264 --enable-libfdk-aac --enable-libmp3lame \
        --disable-ffplay --disable-ffprobe \
        $ffmpeg_gpu_options \
        --enable-small --disable-stripping --disable-debug

    make
    make install
    make distclean
    rm -rf $DIR
}

install_smcroute()
{
    echo "Installing smcroute"
    DIR=$(mktemp -d)
    cd $DIR/
    wget https://github.com/troglobit/smcroute/releases/download/2.4.3/smcroute-$SMCROUTE_VERSION.tar.gz
    tar xaf smcroute-$SMCROUTE_VERSION.tar.gz
    cd smcroute-$SMCROUTE_VERSION
    ./autogen.sh
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var
    make
    make install
    make distclean
    rm -rf $DIR
}

source $THIS_DIR/nmos/install.sh

install_all()
{
    install_common_tools
    install_monitoring_tools
    install_yasm
    install_nasm
    install_x264
    install_fdkaac
    install_mp3
    install_ffmpeg
    install_smcroute
    install_nmos
}
