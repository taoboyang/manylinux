#!/bin/bash

# Stop at any error, show all commands
set -exuo pipefail

if [ "${MANYLINUX_BUILD_FRONTEND:-}" == "" ]; then
	MANYLINUX_BUILD_FRONTEND="docker-buildx"
fi

# Export variable needed by 'docker build --build-arg'
export POLICY
export PLATFORM

# get docker default multiarch image prefix for PLATFORM
if [ "${PLATFORM}" == "x86_64" ]; then
	MULTIARCH_PREFIX="amd64/"
elif [ "${PLATFORM}" == "i686" ]; then
	MULTIARCH_PREFIX="i386/"
	PLATFORM_ARG="linux/i386"
elif [ "${PLATFORM}" == "aarch64" ]; then
	MULTIARCH_PREFIX="arm64v8/"
elif [ "${PLATFORM}" == "ppc64le" ]; then
	MULTIARCH_PREFIX="ppc64le/"
elif [ "${PLATFORM}" == "s390x" ]; then
	MULTIARCH_PREFIX="s390x/"
else
	echo "Unsupported platform: '${PLATFORM}'"
	exit 1
fi

PLATFORM_ARG="linux/${PLATFORM}"
# setup BASEIMAGE and its specific properties
if [ "${POLICY}" == "manylinux2014" ]; then
	if [ "${PLATFORM}" == "s390x" ]; then
		BASEIMAGE="s390x/clefos:7"
	else
		BASEIMAGE="${MULTIARCH_PREFIX}centos:7"
	fi
	DEVTOOLSET_ROOTPATH="/opt/rh/devtoolset-10/root"
	PREPEND_PATH="${DEVTOOLSET_ROOTPATH}/usr/bin:"
	if [ "${PLATFORM}" == "i686" ]; then
		LD_LIBRARY_PATH_ARG="${DEVTOOLSET_ROOTPATH}/usr/lib:${DEVTOOLSET_ROOTPATH}/usr/lib/dyninst"
	else
		LD_LIBRARY_PATH_ARG="${DEVTOOLSET_ROOTPATH}/usr/lib64:${DEVTOOLSET_ROOTPATH}/usr/lib:${DEVTOOLSET_ROOTPATH}/usr/lib64/dyninst:${DEVTOOLSET_ROOTPATH}/usr/lib/dyninst:/usr/local/lib64"
	fi
elif [ "${POLICY}" == "manylinux_2_28" ]; then
	BASEIMAGE="${MULTIARCH_PREFIX}almalinux:8"
	DEVTOOLSET_ROOTPATH="/opt/rh/gcc-toolset-12/root"
	PREPEND_PATH="${DEVTOOLSET_ROOTPATH}/usr/bin:"
	LD_LIBRARY_PATH_ARG="${DEVTOOLSET_ROOTPATH}/usr/lib64:${DEVTOOLSET_ROOTPATH}/usr/lib:${DEVTOOLSET_ROOTPATH}/usr/lib64/dyninst:${DEVTOOLSET_ROOTPATH}/usr/lib/dyninst"
elif [ "${POLICY}" == "musllinux_1_1" ]; then
	BASEIMAGE="${MULTIARCH_PREFIX}alpine:3.12"
	DEVTOOLSET_ROOTPATH=
	PREPEND_PATH=
	LD_LIBRARY_PATH_ARG=
elif [ "${POLICY}" == "musllinux_1_2" ]; then
	BASEIMAGE="${MULTIARCH_PREFIX}alpine:3.19"
	DEVTOOLSET_ROOTPATH=
	PREPEND_PATH=
	LD_LIBRARY_PATH_ARG=
else
	echo "Unsupported policy: '${POLICY}'"
	exit 1
fi
export BASEIMAGE
export DEVTOOLSET_ROOTPATH
export PREPEND_PATH
export LD_LIBRARY_PATH_ARG
export http_proxy="${http_proxy:-}"
export https_proxy="${https_proxy:-}"
export no_proxy="${no_proxy:-}"

BUILD_ARGS_COMMON="
	--build-arg POLICY --build-arg PLATFORM --build-arg BASEIMAGE --build-arg http_proxy=${http_proxy}
	--build-arg https_proxy=${https_proxy} --build-arg no_proxy=${no_proxy}
	--build-arg DEVTOOLSET_ROOTPATH --build-arg PREPEND_PATH --build-arg LD_LIBRARY_PATH_ARG
	--platform ${PLATFORM_ARG}
	--rm -t quay.io/pypa/${POLICY}_${PLATFORM}:${COMMIT_SHA}
	-f docker/Dockerfile docker/
"

if [ "${CI:-}" == "true" ]; then
	# Force plain output on CI
	BUILD_ARGS_COMMON="--progress plain ${BUILD_ARGS_COMMON}"
	# Workaround issue on ppc64le
	if [ ${PLATFORM} == "ppc64le" ] && [ "${MANYLINUX_BUILD_FRONTEND}" == "docker" ]; then
		BUILD_ARGS_COMMON="--network host ${BUILD_ARGS_COMMON}"
	fi
fi

USE_LOCAL_CACHE=0
if [ "${MANYLINUX_BUILD_FRONTEND}" == "docker" ]; then
	docker build ${BUILD_ARGS_COMMON}
elif [ "${MANYLINUX_BUILD_FRONTEND}" == "podman" ]; then
	podman build ${BUILD_ARGS_COMMON}
elif [ "${MANYLINUX_BUILD_FRONTEND}" == "docker-buildx" ]; then
	USE_LOCAL_CACHE=1
	docker buildx build \
		--load \
		--cache-from=type=local,src=$(pwd)/.buildx-cache-${POLICY}_${PLATFORM} \
		--cache-to=type=local,dest=$(pwd)/.buildx-cache-staging-${POLICY}_${PLATFORM},mode=max \
		${BUILD_ARGS_COMMON}
elif [ "${MANYLINUX_BUILD_FRONTEND}" == "buildkit" ]; then
	USE_LOCAL_CACHE=1
	buildctl build \
		--frontend=dockerfile.v0 \
		--local context=./docker/ \
		--local dockerfile=./docker/ \
		--import-cache type=local,src=$(pwd)/.buildx-cache-${POLICY}_${PLATFORM} \
		--export-cache type=local,dest=$(pwd)/.buildx-cache-staging-${POLICY}_${PLATFORM},mode=max \
		--opt build-arg:POLICY=${POLICY} --opt build-arg:PLATFORM=${PLATFORM} --opt build-arg:BASEIMAGE=${BASEIMAGE} \
		--opt "build-arg:DEVTOOLSET_ROOTPATH=${DEVTOOLSET_ROOTPATH}" --opt "build-arg:PREPEND_PATH=${PREPEND_PATH}" --opt "build-arg:LD_LIBRARY_PATH_ARG=${LD_LIBRARY_PATH_ARG}" \
		--output type=docker,name=quay.io/pypa/${POLICY}_${PLATFORM}:${COMMIT_SHA} | docker load
else
	echo "Unsupported build frontend: '${MANYLINUX_BUILD_FRONTEND}'"
	exit 1
fi

docker run --rm -v $(pwd)/tests:/tests:ro quay.io/pypa/${POLICY}_${PLATFORM}:${COMMIT_SHA} /tests/run_tests.sh

if [ ${USE_LOCAL_CACHE} -ne 0 ]; then
	if [ -d $(pwd)/.buildx-cache-${POLICY}_${PLATFORM} ]; then
		rm -rf $(pwd)/.buildx-cache-${POLICY}_${PLATFORM}
	fi
	mv $(pwd)/.buildx-cache-staging-${POLICY}_${PLATFORM} $(pwd)/.buildx-cache-${POLICY}_${PLATFORM}
fi
