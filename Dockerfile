FROM gcc:13 as aws-lc-quic-builder

ARG AWSLC_URL=https://github.com/aws/aws-lc/archive/refs/tags/v1.51.2.tar.gz

# install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake perl golang \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /tmp/aws-lc /cache && \
    cd /tmp/aws-lc && \
    wget -c $AWSLC_URL -O /cache/aws-lc.tar.gz && \
    tar -xzf /cache/aws-lc.tar.gz && \
    cd aws-lc-* && \
    cmake -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/aws-lc \
      -DGO_EXECUTABLE=/usr/bin/go -DPERL_EXECUTABLE=/usr/bin/perl -DFIPS=ON && \
    make -j $(nproc) && \
    make install -j $(nproc) && \
    ldconfig && \
    /opt/aws-lc//bin/openssl version && \
    cd / && \
    rm -rf /tmp/aws-lc

FROM gcc:15 as haproxy-builder

ARG HAPROXY_URL=https://www.haproxy.org/download/3.1/src/haproxy-3.1.7.tar.gz
ARG HAPROXY_CFLAGS="-O3 -g -Wall -Wextra -Wundef -Wdeclaration-after-statement -Wfatal-errors -Wtype-limits -Wshift-negative-value -Wshift-overflow=2 -Wduplicated-cond -Wnull-dereference -fwrapv -Wno-address-of-packed-member -Wno-unused-label -Wno-sign-compare -Wno-unused-parameter -Wno-clobbered -Wno-missing-field-initializers -Wno-cast-function-type -Wno-string-plus-int -Wno-atomic-alignment"
ARG HAPROXY_LDFLAGS=""
ARG HAPROXY_OPTS="TARGET=linux-glibc \
    USE_PCRE2=1 USE_PCRE2_JIT=1 \
    USE_PCRE= USE_PCRE_JIT= \
    USE_GETADDRINFO=1 \
    USE_OPENSSL_AWSLC=1 USE_LIBCRYPT=1 \
    USE_QUIC=1 \
    USE_THREAD=1 \
    USE_NS=1 \
    USE_SLZ=1 USE_ZLIB= \
    "

# install dependencies (pcre2)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=aws-lc-quic-builder /opt/aws-lc /opt/aws-lc
RUN \
    echo "/opt/aws-lc/lib" > /etc/ld.so.conf.d/aws-lc.conf && \
    ldconfig && \
    /opt/aws-lc/bin/openssl version

RUN mkdir -p /tmp/haproxy /cache && \
    cd /tmp/haproxy && \
    wget -c $HAPROXY_URL -O /cache/haproxy.tar.gz && \
    tar -xzf /cache/haproxy.tar.gz && \
    cd haproxy-* && \
    make -j $(nproc) $HAPROXY_OPTS CFLAGS="$HAPROXY_CFLAGS" LDFLAGS="$HAPROXY_LDFLAGS" SSL_INC=/opt/aws-lc/include SSL_LIB=/opt/aws-lc/lib all admin/halog/halog && \
    make -j $(nproc) install-bin && \
    cp admin/halog/halog /usr/local/sbin/halog && \
    /usr/local/sbin/haproxy -vv && \
    cd / && \
    rm -rf /tmp/haproxy

# use baseimage to provide rsyslog as separate process
FROM ghcr.io/phusion/baseimage:noble-1.0.2 as haproxy

# use baseimage-docker's init system
CMD ["/sbin/my_init"]

# update the list of available packages on the system and upgrade the OS
RUN apt-get update && apt-get -y upgrade; \
# install socat and wget
#    apt-get install -y socat wget; \
# download the OCSP Stapling Updater
#    wget https://github.com/pierky/haproxy-ocsp-stapling-updater/raw/master/hapos-upd -P /opt; \
# make the OCSP Stapling Updater script executable
#    chmod u+x /opt/hapos-upd; \
# install dependencies (pcre2)
    apt-get install -y --no-install-recommends \
    libpcre2-8-0 \
    libpcre2-posix3 \
    ca-certificates; \
# clean up APT when done
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*;
    
# Copy the ocsp stapling script for the cron job
#COPY ./ocsp-stapling.sh /usr/local/bin/

# Copy the 'haproxy' script that is supposed to handle haproxy's reload etc.
COPY ./haproxy /etc/init.d/

# Copy the 'run' script that is supposed to run automatically on container's startup
COPY ./run /etc/service/haproxy/

COPY --from=aws-lc-quic-builder /opt/aws-lc/lib /opt/aws-lc/lib
COPY --from=haproxy-builder /usr/local/sbin/haproxy /usr/local/sbin/haproxy
COPY --from=haproxy-builder /usr/local/sbin/halog /usr/local/sbin/halog

# make aws-lc available
RUN \
    echo "/opt/aws-lc/lib" > /etc/ld.so.conf.d/aws-lc.conf && \
    ldconfig && \
# make some haproxy's directories
    mkdir -p /etc/haproxy && \
    mkdir -p /etc/haproxy/errors && \
    mkdir -p /etc/haproxy/certs && \
    mkdir -p /var/lib/haproxy && \
    mkdir -p /var/run/haproxy && \
    /bin/true
