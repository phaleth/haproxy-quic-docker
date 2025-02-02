FROM gcc:14 as wolfssl-quic-builder

ARG WOLFSSL_URL=https://github.com/wolfSSL/wolfssl/archive/refs/tags/v5.7.6-stable.tar.gz
ARG WOLFSSL_OPTS="--enable-haproxy --enable-quic --enable-alpn --enable-aesgcm \
    --enable-aesccm --disable-aescbc --enable-tls13 --disable-oldtls --enable-supportedcurves \
    --enable-curve25519 --enable-ed25519 --enable-curve448 --enable-ed448 \
    --enable-ocsp --enable-ocspstapling --enable-ocspstapling2 \
    --disable-examples --enable-sys-ca-certs --enable-keylog-export --enable-harden \
    --enable-altcertchains \
    "

RUN mkdir -p /tmp/wolfssl /cache && \
    cd /tmp/wolfssl && \
    wget -c $WOLFSSL_URL -O /cache/wolfssl.tar.gz && \
    tar -xzf /cache/wolfssl.tar.gz && \
    cd wolfssl-* && \
    ./autogen.sh && \ 
    ./configure --prefix=/opt/wolfssl $WOLFSSL_OPTS && \
    make -j $(nproc) && \
    make install && \
    cp /opt/wolfssl/lib/libwolfssl.so /usr/lib/ && \
    ldconfig && \
    /opt/wolfssl/bin/wolfssl-config --version && \
    cd / && \
    rm -rf /tmp/wolfssl

FROM gcc:14 as haproxy-builder

ARG HAPROXY_URL=https://www.haproxy.org/download/3.1/src/haproxy-3.1.3.tar.gz
ARG HAPROXY_CFLAGS="-O3 -g -Wall -Wextra -Wundef -Wdeclaration-after-statement -Wfatal-errors -Wtype-limits -Wshift-negative-value -Wshift-overflow=2 -Wduplicated-cond -Wnull-dereference -fwrapv -Wno-address-of-packed-member -Wno-unused-label -Wno-sign-compare -Wno-unused-parameter -Wno-clobbered -Wno-missing-field-initializers -Wno-cast-function-type -Wno-string-plus-int -Wno-atomic-alignment"
ARG HAPROXY_LDFLAGS=""
ARG HAPROXY_OPTS="TARGET=linux-glibc \
    USE_PCRE2=1 USE_PCRE2_JIT=1 \
    USE_PCRE= USE_PCRE_JIT= \
    USE_GETADDRINFO=1 \
    USE_OPENSSL_WOLFSSL=1 USE_LIBCRYPT=1 \
    USE_QUIC=1 \
    USE_THREAD=1 \
    USE_NS=1 \
    USE_SLZ=1 USE_ZLIB= \
    "

# install dependencies (pcre2)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=wolfssl-quic-builder /opt/wolfssl /opt/wolfssl
RUN \
    echo "/opt/wolfssl/lib" > /etc/ld.so.conf.d/wolfssl.conf && \
    ldconfig && \
    /opt/wolfssl/bin/wolfssl-config --version

RUN mkdir -p /tmp/haproxy /cache && \
    cd /tmp/haproxy && \
    wget -c $HAPROXY_URL -O /cache/haproxy.tar.gz && \
    tar -xzf /cache/haproxy.tar.gz && \
    cd haproxy-* && \
    make -j $(nproc) $HAPROXY_OPTS CFLAGS="$HAPROXY_CFLAGS" LDFLAGS="$HAPROXY_LDFLAGS" SSL_INC=/opt/wolfssl/include SSL_LIB=/opt/wolfssl/lib all admin/halog/halog && \
    make -j $(nproc) install-bin  && \
    cp admin/halog/halog /usr/local/sbin/halog && \
    /usr/local/sbin/haproxy -vv && \
    cd / && \
    rm -rf /tmp/haproxy

# use baseimage to provide rsyslog as separate process
FROM ghcr.io/phusion/baseimage:noble-1.0.0 as haproxy

# use baseimage-docker's init system
CMD ["/sbin/my_init"]

# update the list of available packages on the system and upgrade the OS
#RUN apt-get update && apt-get -y upgrade; \
# install socat and wget
#    apt-get install -y socat wget; \
# download the OCSP Stapling Updater
#    wget https://github.com/pierky/haproxy-ocsp-stapling-updater/raw/master/hapos-upd -P /opt; \
# make the OCSP Stapling Updater script executable
#    chmod u+x /opt/hapos-upd
# install dependencies (pcre2)
RUN apt-get update; \
    apt-get install -y --no-install-recommends \
    libpcre2-8-0 \
    libpcre2-posix3 \
    ca-certificates; \
# clean up APT when done
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*;
    
# copy the ocsp stapling script for the cron job
#COPY ./ocsp-stapling.sh /usr/local/bin/

# copy the 'haproxy' script that is supposed to handle haproxy's reload etc.
COPY ./haproxy /etc/init.d/

# copy the 'run' script that is supposed to run automatically on container's startup
COPY ./run /etc/service/haproxy/

COPY --from=wolfssl-quic-builder /opt/wolfssl/lib /opt/wolfssl/lib
COPY --from=haproxy-builder /usr/local/sbin/haproxy /usr/local/sbin/haproxy
COPY --from=haproxy-builder /usr/local/sbin/halog /usr/local/sbin/halog

# make wolfssl available
RUN \
    echo "/opt/wolfssl/lib" > /etc/ld.so.conf.d/wolfssl.conf && \
    ldconfig && \
# create some haproxy's directories
    mkdir -p /etc/haproxy && \
    mkdir -p /etc/haproxy/errors && \
    mkdir -p /etc/haproxy/certs && \
    mkdir -p /var/lib/haproxy && \
    mkdir -p /var/run/haproxy && \
    /bin/true
