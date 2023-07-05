# Docker image that builds haproxy from source + openssl from quictls

FROM gcc:13 as openssl-quic-builder

# ignore these default arguments values, they are overridden by the build command with updated values.
ARG OPENSSL_URL=https://codeload.github.com/quictls/openssl/tar.gz/OpenSSL_1_1_1u+quic
ARG OPENSSL_OPTS="enable-tls1_3 \
    -g -O3 -fstack-protector-strong -Wformat -Werror=format-security \
    -DOPENSSL_TLS_SECURITY_LEVEL=2 -DOPENSSL_USE_NODELETE -DL_ENDIAN \
    -DOPENSSL_PIC -DOPENSSL_CPUID_OBJ -DOPENSSL_IA32_SSE2 \
    -DOPENSSL_BN_ASM_MONT -DOPENSSL_BN_ASM_MONT5 -DOPENSSL_BN_ASM_GF2m \
    -DSHA1_ASM -DSHA256_ASM -DSHA512_ASM -DKECCAK1600_ASM -DMD5_ASM \
    -DAESNI_ASM -DVPAES_ASM -DGHASH_ASM -DECP_NISTZ256_ASM -DX25519_ASM \
    -DX448_ASM -DPOLY1305_ASM -DNDEBUG -Wdate-time -D_FORTIFY_SOURCE=2 \
    "

RUN mkdir -p /tmp/openssl /cache && \
    cd /tmp/openssl && \
    wget -c $OPENSSL_URL -O /cache/openssl.tar.gz && \
    tar -xzf /cache/openssl.tar.gz && \
    cd openssl-* && \
    ./config --libdir=lib --prefix=/opt/quictls $OPENSSL_OPTS && \
    make -j $(nproc) && \
    make install -j $(nproc) && \
    cp /opt/quictls/lib/libcrypto.so /usr/lib/ && \
    cp /opt/quictls/lib/libssl.so /usr/lib/ && \
    ldconfig && \
    /opt/quictls/bin/openssl version -a && \
    cd / && \
    rm -rf /tmp/openssl

FROM gcc:13 as haproxy-builder

# ignore these default arguments values, they are overridden by the build command with updated values.
ARG HAPROXY_URL=http://www.haproxy.org/download/2.8/src/haproxy-2.8.1.tar.gz
ARG HAPROXY_CFLAGS="-O3 -g -Wall -Wextra -Wundef -Wdeclaration-after-statement -Wfatal-errors -Wtype-limits -Wshift-negative-value -Wshift-overflow=2 -Wduplicated-cond -Wnull-dereference -fwrapv -Wno-address-of-packed-member -Wno-unused-label -Wno-sign-compare -Wno-unused-parameter -Wno-clobbered -Wno-missing-field-initializers -Wno-cast-function-type -Wno-string-plus-int -Wno-atomic-alignment"
ARG HAPROXY_LDFLAGS=""
ARG HAPROXY_OPTS="TARGET=linux-glibc \
    USE_PCRE2=1 USE_PCRE2_JIT=1 \
    USE_PCRE= USE_PCRE_JIT= \
    USE_GETADDRINFO=1 \
    USE_OPENSSL=1 USE_LIBCRYPT=1 \
    USE_QUIC=1 \
    USE_THREAD=1 \
    USE_NS=1 \
    USE_SLZ= USE_ZLIB=1 \
    "

# install dependencies (pcre2)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=openssl-quic-builder /opt/quictls /opt/quictls
RUN \
    echo "/opt/quictls/lib" > /etc/ld.so.conf.d/quictls.conf && \
    ldconfig && \
    /opt/quictls/bin/openssl version -a

RUN mkdir -p /tmp/haproxy /cache && \
    cd /tmp/haproxy && \
    wget -c $HAPROXY_URL -O /cache/haproxy.tar.gz && \
    tar -xzf /cache/haproxy.tar.gz && \
    cd haproxy-* && \
    make -j $(nproc) $HAPROXY_OPTS CFLAGS="$HAPROXY_CFLAGS" LDFLAGS="$HAPROXY_LDFLAGS" SSL_INC=/opt/quictls/include SSL_LIB=/opt/quictls/lib all admin/halog/halog && \
    make -j $(nproc) install-bin  && \
    cp admin/halog/halog /usr/local/sbin/halog && \
    /usr/local/sbin/haproxy -vv && \
    cd / && \
    rm -rf /tmp/haproxy

# use baseimage to provides rsyslog as separate process to gain performance
FROM ghcr.io/phusion/baseimage:jammy-1.0.1 as haproxy

# use baseimage-docker's init system
CMD ["/sbin/my_init"]

# update the list of available packages on the system and upgrade the OS
RUN apt-get update && apt-get -y upgrade; \
# install socat and wget
    apt-get install -y socat wget; \
# download the OCSP Stapling Updater
    wget https://github.com/pierky/haproxy-ocsp-stapling-updater/raw/master/hapos-upd -P /opt; \
# make the OCSP Stapling Updater script executable
    chmod u+x /opt/hapos-upd; \
# install dependencies (pcre2)
    apt-get update; \
    apt-get install -y --no-install-recommends \
    libpcre2-8-0 \
    libpcre2-posix3 \
    ca-certificates; \
# clean up APT when done
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*;
    
# Copy the ocsp stapling script for the cron job
COPY ./ocsp-stapling.sh /usr/local/bin/

# Copy the 'haproxy' script that is supposed to handle haproxy's reload etc.
COPY ./haproxy /etc/init.d/

# Copy the 'run' script that is supposed to run automatically on container's startup
COPY ./run /etc/service/haproxy/

COPY --from=openssl-quic-builder /opt/quictls/lib /opt/quictls/lib
COPY --from=haproxy-builder /usr/local/sbin/haproxy /usr/local/sbin/haproxy
COPY --from=haproxy-builder /usr/local/sbin/halog /usr/local/sbin/halog

# make quicktls available
RUN \
    echo "/opt/quictls/lib" > /etc/ld.so.conf.d/quictls.conf && \
    ldconfig && \
# make some haproxy's directories
    mkdir -p /etc/haproxy && \
    mkdir -p /etc/haproxy/errors && \
    mkdir -p /etc/haproxy/certs && \
    mkdir -p /var/lib/haproxy && \
    mkdir -p /var/run/haproxy && \
    /bin/true
